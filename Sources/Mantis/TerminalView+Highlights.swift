import AppKit
import MantisCore

/// Marker colors for session highlights (PDF-style).
enum Marker {
    static let names = ["Yellow", "Green", "Blue", "Pink", "Orange"]
    static let colors: [RGB] = [RGB(0xFF, 0xD5, 0x4A), RGB(0x7C, 0xE3, 0x8B), RGB(0x6C, 0xB8, 0xFF),
                                RGB(0xFF, 0x7A, 0xC6), RGB(0xFF, 0x9F, 0x43)]
    static func color(_ i: Int) -> RGB { colors[((i % colors.count) + colors.count) % colors.count] }

    /// Small round swatch for menus.
    static func swatch(_ i: Int) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color(i).nsColor.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true
        }
    }
}

/// Session highlights: select text → mark it in a color, add notes, jump between
/// marks, copy them all. Kept for the lifetime of the pane.
extension TerminalView {

    // MARK: Create / remove

    @objc func highlightSelection(_ sender: Any?) { addHighlight(color: markerColor) }

    /// Menu items tagged 0…4 (⌥⌘1…5). With a selection: highlight in that color. Always: make it the current color.
    @objc func highlightWithColor(_ sender: NSMenuItem) {
        markerColor = sender.tag
        if selection != nil { addHighlight(color: sender.tag) } else { showToast("Marker: \(Marker.names[sender.tag]) — select text, then ⌘L") }
    }

    private func addHighlight(color: Int) {
        guard let sel = selection else { showToast("Select text to highlight"); return }
        terminal.lock.lock()
        annotations.prune(terminal)
        let a = annotations.add(sel, colorIndex: color, in: terminal)
        terminal.lock.unlock()
        guard a != nil else { showToast("Nothing to highlight"); return }
        selection = nil
        showToast("Highlighted in \(Marker.names[color])")
        needsDisplay = true
    }

    @objc func removeHighlightAction(_ sender: Any?) {
        if let item = sender as? NSMenuItem, let id = item.representedObject as? UUID {
            annotations.remove(id: id)
        } else if let sel = selection {
            let n = annotations.remove(overlapping: sel)
            showToast(n == 0 ? "No highlight in selection" : "Removed \(n) highlight\(n == 1 ? "" : "s")")
            selection = nil
        } else {
            showToast("Select highlighted text (or right-click a highlight) to remove it")
        }
        needsDisplay = true
    }

    @objc func recolorHighlight(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        annotations.setColor(id: id, sender.tag)
        markerColor = sender.tag
        needsDisplay = true
    }

    @objc func editHighlightNote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let w = window,
              let a = annotations.items.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = a.note == nil ? "Add note" : "Edit note"
        alert.informativeText = "“\(a.text.prefix(120))\(a.text.count > 120 ? "…" : "")”"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = a.note ?? ""
        field.placeholderString = "Note (shown on hover)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        if a.note != nil { alert.addButton(withTitle: "Delete Note") }
        alert.beginSheetModal(for: w) { [weak self] r in
            switch r {
            case .alertFirstButtonReturn: self?.annotations.setNote(id: id, field.stringValue)
            case .alertThirdButtonReturn: self?.annotations.setNote(id: id, nil)
            default: return
            }
            self?.needsDisplay = true
        }
        DispatchQueue.main.async { w.attachedSheet?.makeFirstResponder(field) }
    }

    @objc func copyHighlightText(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let a = annotations.items.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(a.text, forType: .string)
        showToast("Copied highlight")
    }

    @objc func copyAllHighlights(_ sender: Any?) {
        terminal.lock.lock()
        let md = annotations.markdown(in: terminal, colorNames: Marker.names)
        terminal.lock.unlock()
        guard !md.isEmpty else { showToast("No highlights in this session"); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        showToast("Copied \(md.components(separatedBy: "\n- ").count) highlight(s) as Markdown")
    }

    @objc func clearAllHighlights(_ sender: Any?) {
        annotations.removeAll()
        needsDisplay = true
        showToast("Cleared all highlights")
    }

    // MARK: Navigate

    @objc func nextHighlight(_ sender: Any?) { jumpHighlight(forward: true) }
    @objc func previousHighlight(_ sender: Any?) { jumpHighlight(forward: false) }

    private func jumpHighlight(forward: Bool) {
        terminal.lock.lock()
        let anchor = terminal.droppedLines + terminal.absIndex(viewportRow: 0) + terminal.rows / 3
        let target = annotations.neighbor(of: anchor, forward: forward, in: terminal)
        terminal.lock.unlock()
        if let target { reveal(target) } else { showToast(annotations.isEmpty ? "No highlights (select text, ⌘L)" : "No more highlights") }
    }

    @objc func goToHighlight(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let a = annotations.items.first(where: { $0.id == id }) else { return }
        reveal(a)
    }

    /// Scroll a highlight into view (a third of the way down) and flash it.
    func reveal(_ a: Annotation) {
        terminal.lock.lock()
        let abs = a.range.start.line - terminal.droppedLines
        let top = terminal.absIndex(viewportRow: 0)
        if abs < top || abs >= top + terminal.rows {
            terminal.scrollOffset = max(0, min(terminal.scrollback.count, terminal.scrollback.count - (abs - terminal.rows / 3)))
        }
        terminal.lock.unlock()
        bookmarkFlash = (a.range.start.line, Date().addingTimeInterval(0.6))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.needsDisplay = true }
        needsDisplay = true
    }

    /// Items for the "Go to Highlight" menu (live highlights in document order).
    func highlightMenuItems() -> [NSMenuItem] {
        terminal.lock.lock()
        let live = annotations.live(in: terminal).sorted { $0.range.start < $1.range.start }
        terminal.lock.unlock()
        return live.map { a in
            var title = a.text.replacingOccurrences(of: "\n", with: " ⏎ ")
            if title.count > 48 { title = String(title.prefix(47)) + "…" }
            if a.note != nil { title += "  ✎" }
            let it = NSMenuItem(title: title, action: #selector(goToHighlight(_:)), keyEquivalent: "")
            it.representedObject = a.id
            it.image = Marker.swatch(a.colorIndex)
            it.toolTip = a.note
            return it
        }
    }

    // MARK: Context menu & hover

    func addHighlightMenuItems(to m: NSMenu, event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        terminal.lock.lock()
        let col = max(0, min(terminal.cols - 1, Int((p.x - padX) / cellW)))
        let row = max(0, min(terminal.rows - 1, Int((p.y - padY) / cellH)))
        let hit = annotations.annotation(at: terminal.stablePoint(viewportRow: row, col: col), in: terminal)
        terminal.lock.unlock()

        if let a = hit {
            let colors = NSMenu()
            for i in Marker.names.indices {
                let c = NSMenuItem(title: Marker.names[i], action: #selector(recolorHighlight(_:)), keyEquivalent: "")
                c.tag = i; c.representedObject = a.id; c.image = Marker.swatch(i); c.state = i == a.colorIndex ? .on : .off
                colors.addItem(c)
            }
            let colorItem = NSMenuItem(title: "Highlight Color", action: nil, keyEquivalent: ""); colorItem.submenu = colors
            colorItem.image = Marker.swatch(a.colorIndex)
            m.addItem(colorItem)
            for (title, sel) in [(a.note == nil ? "Add Note…" : "Edit Note…", #selector(editHighlightNote(_:))),
                                 ("Copy Highlighted Text", #selector(copyHighlightText(_:))),
                                 ("Remove Highlight", #selector(removeHighlightAction(_:)))] {
                let it = NSMenuItem(title: title, action: sel, keyEquivalent: ""); it.representedObject = a.id; m.addItem(it)
            }
            m.addItem(.separator())
        } else if selection != nil {
            let colors = NSMenu()
            for i in Marker.names.indices {
                let c = NSMenuItem(title: Marker.names[i], action: #selector(highlightWithColor(_:)), keyEquivalent: "")
                c.tag = i; c.image = Marker.swatch(i); colors.addItem(c)
            }
            let item = NSMenuItem(title: "Highlight Selection", action: nil, keyEquivalent: ""); item.submenu = colors
            item.image = Marker.swatch(markerColor)
            m.addItem(item)
            m.addItem(.separator())
        }
    }

    /// Show a highlight's note as a tooltip while hovering it.
    func updateHighlightTooltip(_ event: NSEvent) {
        guard !annotations.isEmpty else { if toolTip != nil { toolTip = nil }; return }
        let p = convert(event.locationInWindow, from: nil)
        terminal.lock.lock()
        let col = max(0, min(terminal.cols - 1, Int((p.x - padX) / cellW)))
        let row = max(0, min(terminal.rows - 1, Int((p.y - padY) / cellH)))
        let note = annotations.annotation(at: terminal.stablePoint(viewportRow: row, col: col), in: terminal)?.note
        terminal.lock.unlock()
        if toolTip != note { toolTip = note }
    }

    // MARK: Drawing

    /// Folded-corner marker at the end of highlights that carry a note.
    func drawHighlightNoteMarkers(_ ctx: CGContext, marks: [Annotation], firstStable: Int, rows: Int) {
        for a in marks where a.note != nil {
            let r = a.range.end.line - firstStable
            guard r >= 0 && r < rows else { continue }
            let x = padX + CGFloat(a.range.end.col + 1) * cellW, y = padY + CGFloat(r) * cellH
            let s = min(cellW, cellH) * 0.55
            ctx.setFillColor(Marker.color(a.colorIndex).cgColor)
            ctx.move(to: CGPoint(x: x - s, y: y)); ctx.addLine(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: y + s))
            ctx.closePath(); ctx.fillPath()
        }
    }

    #if DEBUG
    /// Used by headless snapshot verification (MANTIS_SNAPSHOT_ACTIONS=demoHighlights:).
    @objc func demoHighlights(_ sender: Any?) {
        terminal.lock.lock()
        for (i, word) in ["ERROR type mismatch", "3f9a2c1d", "Parser.swift:42:7", "FAILED health check", "bookmarks + badge"].enumerated() {
            if let m = terminal.search(word).first {
                annotations.add(m, colorIndex: [3, 1, 0, 4, 2][i], note: i == 1 ? "the bad deploy" : nil, in: terminal)
            }
        }
        terminal.lock.unlock()
        needsDisplay = true
    }
    #endif
}
