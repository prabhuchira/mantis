import AppKit
import MantisCore

/// Quick-win features layered on TerminalView:
///  1 hint mode · 2 ⌘-click file:line · 3 copy as HTML · 4 paste preview · 5 highlight rules (renderer)
///  6 bookmarks · 7 secure keyboard entry (App.swift) · 8 badge · 9 unfocused split dimming · 10 cursor trail
extension TerminalView {

    // MARK: - Toast (feedback for copy/open actions)

    func showToast(_ text: String) {
        toast = (text, Date().addingTimeInterval(1.6))
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in self?.needsDisplay = true }
    }

    func drawToast(_ ctx: CGContext) {
        guard let (text, until) = toast, Date() < until else { return }
        let font = NSFont.systemFont(ofSize: max(11, fontSizeValue - 1), weight: .medium)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = attr.size()
        let box = CGRect(x: (bounds.width - size.width) / 2 - 12, y: bounds.height - size.height - 26,
                         width: size.width + 24, height: size.height + 10)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        attr.draw(at: NSPoint(x: box.minX + 12, y: box.minY + 5))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 1. Hint mode (⇧⌘H): label every URL / path / hash / IP, type the label to act

    var hintActive: Bool { !hintMatches.isEmpty }

    @objc func enterHintMode(_ sender: Any?) {
        terminal.lock.lock()
        let rows = (0..<terminal.rows).map { terminal.viewportRow($0) }
        terminal.lock.unlock()
        let matches = Detector.find(in: rows)
        guard !matches.isEmpty else { showToast("No links, paths, hashes or IPs on screen"); return }
        hintMatches = matches
        hintLabels = HintLabels.generate(matches.count)
        hintTyped = ""
        hintCopyOnly = false
        needsDisplay = true
    }

    func exitHintMode() {
        hintMatches = []; hintLabels = []; hintTyped = ""
        needsDisplay = true
    }

    /// Returns after consuming the key. Lowercase label = open, Uppercase (⇧) = copy.
    func handleHintKey(_ event: NSEvent) {
        if event.keyCode == 53 { exitHintMode(); return }                     // esc
        if event.keyCode == 51 { if !hintTyped.isEmpty { hintTyped.removeLast() }; needsDisplay = true; return }
        guard let ch = event.charactersIgnoringModifiers?.first, ch.isLetter else { return }
        if event.modifierFlags.contains(.shift) { hintCopyOnly = true }
        hintTyped += ch.lowercased()
        let candidates = hintLabels.enumerated().filter { $0.element.hasPrefix(hintTyped) }
        if candidates.isEmpty { exitHintMode(); return }
        if candidates.count == 1, candidates[0].element == hintTyped {
            let m = hintMatches[candidates[0].offset]
            let copy = hintCopyOnly
            exitHintMode()
            activate(m, copyOnly: copy)
            return
        }
        needsDisplay = true
    }

    func drawHints(_ ctx: CGContext) {
        guard hintActive else { return }
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)
        let font = NSFont.monospacedSystemFont(ofSize: fontSizeValue, weight: .heavy)
        for (i, m) in hintMatches.enumerated() where hintLabels[i].hasPrefix(hintTyped) {
            let y = padY + CGFloat(m.row) * cellH
            // underline the target (every row it wraps across)
            ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.85).cgColor)
            for seg in m.segments {
                ctx.fill(CGRect(x: padX + CGFloat(seg.cols.lowerBound) * cellW, y: padY + CGFloat(seg.row + 1) * cellH - 2,
                                width: CGFloat(seg.cols.count) * cellW, height: 2))
            }
            // label chip over the first cells
            let label = hintLabels[i]
            let rest = String(label.dropFirst(hintTyped.count))
            let chip = CGRect(x: padX + CGFloat(m.cols.lowerBound) * cellW, y: y,
                              width: CGFloat(max(1, label.count)) * cellW + 4, height: cellH)
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
            let a = NSMutableAttributedString(string: hintTyped, attributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(0.35)])
            a.append(NSAttributedString(string: rest, attributes: [.font: font, .foregroundColor: NSColor.black]))
            NSGraphicsContext.saveGraphicsState()
            a.draw(at: NSPoint(x: chip.minX + 2, y: chip.minY + (cellH - a.size().height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - Acting on a detected match (shared by hints and ⌘-click)

    func activate(_ m: TextMatch, copyOnly: Bool) {
        if copyOnly || m.kind == .hash || m.kind == .ip {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(m.text, forType: .string)
            showToast("Copied \(m.text)")
            return
        }
        switch m.kind {
        case .url:
            if let url = URL(string: m.text) { NSWorkspace.shared.open(url); showToast("Opening \(m.text)") }
        case .path:
            openFileLocation(FileLocation.parse(m.text))
        default: break
        }
    }

    /// 2. Open `file[:line[:col]]` in the configured editor (or the default app).
    func openFileLocation(_ loc: FileLocation) {
        let cwd = terminal.workingDirectory ?? pty.currentDirectory
        let path = loc.resolved(cwd: cwd)
        guard FileManager.default.fileExists(atPath: path) else {
            showToast("Not found: \(path)")
            return
        }
        if let template = config.editor {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", loc.command(template: template, absolutePath: path)]
            do { try p.run(); showToast("Opening \((path as NSString).lastPathComponent)\(loc.line.map { ":\($0)" } ?? "")") }
            catch { showToast("editor failed: \(error.localizedDescription)") }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            showToast("Opening \((path as NSString).lastPathComponent)")
        }
    }

    /// ⌘-click: OSC 8 hyperlink → detected url/path/hash/ip → system data detector fallback.
    func commandClick(_ event: NSEvent) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        terminal.lock.lock()
        let col = max(0, min(terminal.cols - 1, Int((p.x - padX) / cellW)))
        let r = max(0, min(terminal.rows - 1, Int((p.y - padY) / cellH)))
        let rows = (0..<terminal.rows).map { terminal.viewportRow($0) }
        let row = rows[r]
        let linkID = col < row.cells.count ? Int(row.cells[col].link) : 0
        let explicit = linkID > 0 && linkID < terminal.hyperlinks.count ? terminal.hyperlinks[linkID] : nil
        terminal.lock.unlock()
        if let explicit, let url = URL(string: explicit) { NSWorkspace.shared.open(url); return true }
        if let m = Detector.find(in: rows).first(where: { $0.contains(row: r, col: col) }) {
            activate(m, copyOnly: false)
            return true
        }
        return openLink(at: event)
    }

    // MARK: - 3. Copy as HTML (⌥⌘C)

    @objc func copyAsHTML(_ sender: Any?) {
        guard let sel = selection else { showToast("Nothing selected"); return }
        terminal.lock.lock()
        let html = terminal.html(in: sel, fontFamily: "\(config.fontFamily), Menlo, monospace")
        let plain = terminal.text(in: sel)
        terminal.lock.unlock()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(plain, forType: .string)
        if let data = html.data(using: .utf8),
           let attr = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                    .characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil),
           let rtf = attr.rtf(from: NSRange(location: 0, length: attr.length)) {
            pb.setData(rtf, forType: .rtf)
        }
        showToast("Copied with colors")
    }

    // MARK: - 4. Paste preview (editable) for multi-line / unsafe pastes

    func presentPastePreview(_ text: String, bracketed: Bool) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Review paste"
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        a.informativeText = "\(lines) line\(lines == 1 ? "" : "s"), \(text.count) characters" +
            (bracketed ? "" : ". Newlines will run commands immediately.") + " Edit before pasting if needed."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let tv = NSTextView(frame: scroll.bounds)
        tv.isRichText = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.string = text
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        a.accessoryView = scroll
        a.addButton(withTitle: "Paste")
        a.addButton(withTitle: "Paste as One Line")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] resp in
            guard let self else { return }
            var edited = tv.string
            switch resp {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn:
                edited = edited.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: " ")
            default: return
            }
            self.sendPaste(edited, bracketed: bracketed)
        }
        DispatchQueue.main.async { w.attachedSheet?.makeFirstResponder(tv) }
    }

    // MARK: - 6. Bookmarks (⌘B toggle, ⌘↑ / ⌘↓ jump)

    @objc func toggleBookmark(_ sender: Any?) {
        terminal.lock.lock()
        let line = terminal.droppedLines + terminal.scrollback.count + terminal.cursorY
        terminal.lock.unlock()
        if bookmarks.remove(line) == nil { bookmarks.insert(line); showToast("Bookmarked line") }
        else { showToast("Bookmark removed") }
        needsDisplay = true
    }

    @objc func clearBookmarks(_ sender: Any?) { bookmarks.removeAll(); needsDisplay = true }
    @objc func previousBookmark(_ sender: Any?) { jumpBookmark(forward: false) }
    @objc func nextBookmark(_ sender: Any?) { jumpBookmark(forward: true) }

    private func jumpBookmark(forward: Bool) {
        terminal.lock.lock()
        let dropped = terminal.droppedLines
        bookmarks = bookmarks.filter { $0 >= dropped } // forget marks evicted from scrollback
        let top = dropped + terminal.absIndex(viewportRow: 0)
        let anchor = top + terminal.rows / 3 // marks are placed a third of the way down
        let sorted = bookmarks.sorted()
        let target = forward ? sorted.first(where: { $0 > anchor }) : sorted.last(where: { $0 < anchor })
        if let target {
            let abs = target - dropped
            terminal.scrollOffset = max(0, min(terminal.scrollback.count, terminal.scrollback.count - (abs - terminal.rows / 3)))
            bookmarkFlash = (target, Date().addingTimeInterval(0.6))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.needsDisplay = true }
        }
        terminal.lock.unlock()
        if target == nil { showToast(bookmarks.isEmpty ? "No bookmarks (⌘B to add)" : "No more bookmarks") }
        needsDisplay = true
    }

    func drawBookmarks(_ ctx: CGContext, firstStable: Int, rows: Int) {
        guard !bookmarks.isEmpty || bookmarkFlash != nil else { return }
        for r in 0..<rows {
            let stable = firstStable + r
            let y = padY + CGFloat(r) * cellH
            if let f = bookmarkFlash, f.line == stable, Date() < f.until {
                ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.22).cgColor)
                ctx.fill(CGRect(x: 0, y: y, width: bounds.width, height: cellH))
            }
            if bookmarks.contains(stable) {
                ctx.setFillColor(NSColor.systemBlue.cgColor)
                ctx.addPath(CGPath(roundedRect: CGRect(x: 1, y: y + 2, width: max(3, padX - 3), height: cellH - 4),
                                   cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
                ctx.fillPath()
            }
        }
    }

    // MARK: - 8. Badge (large faded label, e.g. PROD / hostname)

    @objc func setBadge(_ sender: Any?) {
        guard let w = window else { return }
        let a = NSAlert()
        a.messageText = "Set badge for this pane"
        a.informativeText = "Tokens: {host} {user} {cwd} {title}. Leave empty to use the config default."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = badgeOverride ?? config.badge ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "Set"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.badgeOverride = field.stringValue.isEmpty ? nil : field.stringValue
            self?.redrawAll()
        }
        DispatchQueue.main.async { w.attachedSheet?.makeFirstResponder(field) }
    }

    func badgeText() -> String? {
        guard let fmt = badgeOverride ?? config.badge, !fmt.isEmpty else { return nil }
        var s = fmt
        if s.contains("{host}") {
            var buf = [CChar](repeating: 0, count: 256); gethostname(&buf, buf.count)
            let host = String(cString: buf).replacingOccurrences(of: ".local", with: "")
            s = s.replacingOccurrences(of: "{host}", with: host)
        }
        s = s.replacingOccurrences(of: "{user}", with: NSUserName())
        if s.contains("{cwd}") {
            if Date().timeIntervalSince(cwdCache.at) > 1 { cwdCache = (terminal.workingDirectory ?? pty.currentDirectory ?? "", Date()) }
            s = s.replacingOccurrences(of: "{cwd}", with: (cwdCache.value as NSString).lastPathComponent)
        }
        if s.contains("{title}") { s = s.replacingOccurrences(of: "{title}", with: terminal.title) }
        return s
    }

    func drawBadge(_ ctx: CGContext, fg: RGB) {
        guard let text = badgeText(), !text.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: max(24, fontSizeValue * 2.6), weight: .heavy)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: fg.nsColor.withAlphaComponent(0.09)])
        let size = attr.size()
        NSGraphicsContext.saveGraphicsState()
        attr.draw(at: NSPoint(x: bounds.width - size.width - padX - 10, y: padY + 4))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 9. Dim unfocused splits

    func drawUnfocusedDim(_ ctx: CGContext, bg: RGB) {
        guard superview is NSSplitView, !isFocusedPane, config.unfocusedSplitOpacity < 1 else { return }
        ctx.setFillColor(bg.nsColor.withAlphaComponent(1 - config.unfocusedSplitOpacity).cgColor)
        ctx.fill(bounds)
    }

    // MARK: - 10. Cursor trail (smear when the cursor jumps)

    func drawTrail(_ ctx: CGContext, to rect: CGRect, color: RGB) {
        defer { lastCursorRect = rect }
        guard config.cursorTrail, isFocusedPane else { return }
        if let last = lastCursorRect, last.origin != rect.origin {
            let dx = abs(last.minX - rect.minX), dy = abs(last.minY - rect.minY)
            if dy > 0.5 || dx > cellW * 1.5 { // ignore ordinary typing (one-cell moves)
                trailFrom = last; trailStart = Date()
                trailTimer?.invalidate()
                trailTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                    guard let self else { t.invalidate(); return }
                    self.needsDisplay = true
                    if Date().timeIntervalSince(self.trailStart) > Self.trailDuration { t.invalidate(); self.trailFrom = nil }
                }
            }
        }
        guard let from = trailFrom else { return }
        let t = min(1, Date().timeIntervalSince(trailStart) / Self.trailDuration)
        guard t < 1 else { return }
        let ease = 1 - pow(1 - t, 3) // ease-out cubic: the tail catches up to the cursor
        let tail = CGRect(x: from.minX + (rect.minX - from.minX) * ease, y: from.minY + (rect.minY - from.minY) * ease,
                          width: rect.width, height: rect.height)
        let steps = 10
        for i in 0..<steps {
            let f = CGFloat(i) / CGFloat(steps)
            let r = CGRect(x: tail.minX + (rect.minX - tail.minX) * f, y: tail.minY + (rect.minY - tail.minY) * f,
                           width: rect.width, height: rect.height)
            ctx.setFillColor(color.nsColor.withAlphaComponent(0.45 * (1 - t) * f).cgColor)
            ctx.fill(r)
        }
    }

    static let trailDuration = 0.16
}
