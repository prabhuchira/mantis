import AppKit
import CoreText
import MantisCore

/// One terminal "surface" (Ghostty: src/Surface.zig + macos SurfaceView_AppKit.swift).
/// Owns a Terminal + PTYProcess, renders the grid, and translates AppKit input.
final class TerminalView: NSView, NSTextInputClient {
    let config: Config
    let terminal: Terminal
    let pty: PTYProcess

    // Font & metrics
    private var fontSize: CGFloat
    private var fonts: [CTFont] = [] // regular, bold, italic, boldItalic
    private(set) var cellW: CGFloat = 8
    private(set) var cellH: CGFloat = 16
    private var ascent: CGFloat = 12
    private var kerns: [CGFloat] = [0, 0, 0, 0] // per-font tracking so every glyph lands on the cell grid
    var padX: CGFloat { config.windowPaddingX }
    var padY: CGFloat { config.windowPaddingY }
    var fontSizeValue: CGFloat { fontSize }

    // State
    var selection: Selection?
    private var selecting = false
    private var markedText = NSMutableAttributedString()
    private var blinkOn = true
    private var blinkTimer: Timer?
    private var scrollAccum: CGFloat = 0
    private var exited = false
    private var exitCode: Int32 = 0
    private var flashUntil: Date = .distantPast
    private var lastMouseCell: (Int, Int)? = nil
    private let redrawLock = NSLock()
    private var redrawPending = false

    // Search (Cmd+F)
    private var searchField: NSSearchField?
    private var searchMatches: [Selection] = []
    private var searchIndex = 0

    // Extras state (see TerminalView+Extras.swift)
    var toast: (String, Date)?
    var hintMatches: [TextMatch] = []
    var hintLabels: [String] = []
    var hintTyped = ""
    var hintCopyOnly = false
    var bookmarks = Set<Int>()
    var bookmarkFlash: (line: Int, until: Date)?
    var badgeOverride: String?
    var cwdCache: (value: String, at: Date) = ("", .distantPast)
    var trailFrom: CGRect?
    var trailStart = Date.distantPast
    var lastCursorRect: CGRect?
    var trailTimer: Timer?

    var onTitle: ((String) -> Void)?
    var onCwd: ((String) -> Void)?
    var onClose: ((TerminalView) -> Void)?
    var onFocus: ((TerminalView) -> Void)?

    init(config: Config) {
        self.config = config
        self.fontSize = config.fontSize
        terminal = Terminal(cols: config.windowWidth, rows: config.windowHeight, scrollbackLimit: config.scrollbackLimit)
        pty = PTYProcess(terminal: terminal)
        super.init(frame: .zero)
        config.apply(to: terminal)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        updateFonts()
        wireTerminal()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { config.backgroundOpacity >= 1 }

    /// Size that fits `cols x rows` cells plus padding.
    var preferredContentSize: NSSize {
        NSSize(width: CGFloat(config.windowWidth) * cellW + 2 * padX, height: CGFloat(config.windowHeight) * cellH + 2 * padY)
    }

    // MARK: - Setup

    private func wireTerminal() {
        terminal.onResponse = { [weak self] bytes in self?.pty.write(bytes) }
        terminal.onTitle = { [weak self] t in DispatchQueue.main.async { self?.onTitle?(t) } }
        terminal.onWorkingDirectory = { [weak self] d in DispatchQueue.main.async { self?.onCwd?(d) } }
        terminal.onBell = { [weak self] in DispatchQueue.main.async { self?.bell() } }
        terminal.onClipboardWrite = { text in
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        terminal.onNotification = { title, body in
            DispatchQueue.main.async { Notifier.post(title: title, body: body) }
        }
        pty.onOutput = { [weak self] in self?.scheduleRedraw() }
        pty.onExit = { [weak self] code in
            DispatchQueue.main.async { self?.processExited(code) }
        }
    }

    func start() {
        let (c, r) = gridSize(for: bounds.size)
        terminal.lock.lock(); terminal.resize(cols: c, rows: r); terminal.lock.unlock()
        do {
            try pty.start(config: config, cols: c, rows: r)
        } catch {
            terminal.lock.lock(); terminal.feed("\u{1B}[31mfailed to start shell: \(error.localizedDescription)\u{1B}[0m\r\n"); terminal.lock.unlock()
        }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self, self.terminal.cursorBlink, self.isFocused else { return }
            self.blinkOn.toggle()
            self.setNeedsDisplay(self.cursorRect.insetBy(dx: -2, dy: -2))
        }
    }

    func shutdown() {
        blinkTimer?.invalidate()
        pty.onExit = nil
        pty.terminate()
    }

    private func updateFonts() {
        let base = config.makeFont(size: fontSize)
        let fm = NSFontManager.shared
        let bold = fm.convert(base, toHaveTrait: .boldFontMask)
        let italic = fm.convert(base, toHaveTrait: .italicFontMask)
        let bi = fm.convert(bold, toHaveTrait: .italicFontMask)
        fonts = [base, bold, italic, bi].map { $0 as CTFont }
        let adv = ("M" as NSString).size(withAttributes: [.font: base]).width
        cellW = ceil(adv)
        kerns = fonts.map { f in
            var g: CGGlyph = 0; var u: UniChar = 0x4D
            CTFontGetGlyphsForCharacters(f, &u, &g, 1)
            var a = CGSize.zero
            CTFontGetAdvancesForGlyphs(f, .horizontal, &g, &a, 1)
            return cellW - a.width
        }
        ascent = ceil(base.ascender)
        cellH = ceil(base.ascender - base.descender + base.leading)
        if let w = window { w.contentResizeIncrements = NSSize(width: cellW, height: cellH) }
    }

    func gridSize(for size: NSSize) -> (Int, Int) {
        (max(2, Int((size.width - 2 * padX) / cellW)), max(1, Int((size.height - 2 * padY) / cellH)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGrid()
    }

    private func updateGrid() {
        let (c, r) = gridSize(for: bounds.size)
        terminal.lock.lock()
        let changed = c != terminal.cols || r != terminal.rows
        if changed { terminal.resize(cols: c, rows: r) }
        terminal.lock.unlock()
        if changed {
            pty.resize(cols: c, rows: r, pixelWidth: Int(CGFloat(c) * cellW), pixelHeight: Int(CGFloat(r) * cellH))
            if searchField != nil { runSearch() }
        }
        needsDisplay = true
    }

    /// Coalesce redraw requests from the IO thread (Ghostty wakes its renderer thread via an xev.Async).
    private func scheduleRedraw() {
        redrawLock.lock()
        if redrawPending { redrawLock.unlock(); return }
        redrawPending = true
        redrawLock.unlock()
        // Synchronized output (mode 2026): hold frames until the app finishes, max ~150ms.
        let delay: Double = terminal.modes.synchronizedOutput ? 0.15 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.redrawLock.lock(); self.redrawPending = false; self.redrawLock.unlock()
            self.needsDisplay = true
        }
    }

    // MARK: - Rendering

    private var isFocused: Bool { window?.isKeyWindow == true && window?.firstResponder === self }
    var isFocusedPane: Bool { isFocused }

    private var cursorRect: NSRect {
        terminal.lock.lock(); defer { terminal.lock.unlock() }
        let y = terminal.cursorY + terminal.scrollOffset
        return NSRect(x: padX + CGFloat(terminal.cursorX) * cellW, y: padY + CGFloat(y) * cellH, width: cellW * 2, height: cellH)
    }

    private struct Snapshot {
        var rows: [Row]
        var cols: Int
        var cursor: (x: Int, y: Int)?
        var cursorShape: Terminal.CursorShape
        var cursorWide: Bool
        var firstStable: Int
        var reverse: Bool
        var fg: RGB, bg: RGB, cursorColor: RGB
        var palette: [RGB]
        var hyperlinks: [String]
    }

    private func snapshot() -> Snapshot {
        terminal.lock.lock(); defer { terminal.lock.unlock() }
        let t = terminal
        let rows = (0..<t.rows).map { t.viewportRow($0) }
        let cy = t.cursorY + t.scrollOffset
        var cursor: (Int, Int)? = nil
        if t.modes.cursorVisible && cy < t.rows { cursor = (t.cursorX, cy) }
        let wide = cy < t.rows && t.cursorX < rows[cy].cells.count && rows[cy].cells[t.cursorX].width == 2
        return Snapshot(rows: rows, cols: t.cols, cursor: cursor, cursorShape: t.cursorShape, cursorWide: wide,
                        firstStable: t.droppedLines + t.absIndex(viewportRow: 0), reverse: t.modes.reverseVideo,
                        fg: t.defaultFG, bg: t.defaultBG, cursorColor: t.cursorColor, palette: t.palette,
                        hyperlinks: t.hyperlinks)
    }

    private func resolve(_ c: TermColor, _ s: Snapshot, fg: Bool) -> RGB {
        switch c {
        case .default: return fg ? s.fg : s.bg
        case .indexed(let i): return s.palette[Int(i)]
        case .rgb(let v): return v
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = snapshot()
        let defaultBG = s.reverse ? s.fg : s.bg
        let opacity = config.backgroundOpacity

        ctx.clear(bounds)
        ctx.setFillColor(defaultBG.nsColor.withAlphaComponent(opacity).cgColor)
        ctx.fill(bounds)
        drawBadge(ctx, fg: s.reverse ? s.bg : s.fg)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let selBG = config.selectionBackground
        let matchBG = RGB(0x6B, 0x55, 0x1E), currentMatchBG = RGB(0xC9, 0x8E, 0x1A)
        let currentMatch = searchMatches.indices.contains(searchIndex) ? searchMatches[searchIndex] : nil

        for (r, row) in s.rows.enumerated() {
            let y = padY + CGFloat(r) * cellH
            guard NSRect(x: 0, y: y, width: bounds.width, height: cellH).intersects(dirtyRect) else { continue }
            let stable = s.firstStable + r
            let n = min(row.cells.count, s.cols)

            // Resolve per-cell colors once.
            var fgs = [RGB](repeating: s.fg, count: n)
            var bgs = [RGB?](repeating: nil, count: n) // nil = default background (transparent-capable)
            let highlights = config.highlights.isEmpty ? nil : HighlightRule.apply(config.highlights, to: row)
            for x in 0..<n {
                let c = row.cells[x]
                var fg = resolve(c.fg, s, fg: true), bg = resolve(c.bg, s, fg: false)
                var bgIsDefault = c.bg == .default
                if c.attrs.contains(.inverse) != s.reverse { swap(&fg, &bg); bgIsDefault = false }
                if c.attrs.contains(.bold), case .indexed(let i) = c.fg, i < 8 { fg = s.palette[Int(i) + 8] } // bold-is-bright
                if c.attrs.contains(.dim) { fg = fg.blended(with: bg, 0.45) }
                if c.attrs.contains(.hidden) { fg = bg }
                else if let h = highlights?[x] { fg = h }
                if let sel = selection, sel.contains(line: stable, col: x) { bg = selBG; bgIsDefault = false }
                else if !searchMatches.isEmpty, searchMatches.contains(where: { $0.contains(line: stable, col: x) }) {
                    bg = (currentMatch?.contains(line: stable, col: x) ?? false) ? currentMatchBG : matchBG; bgIsDefault = false
                }
                fg = fg.ensuringContrast(against: bg, ratio: config.minimumContrast)
                fgs[x] = fg
                bgs[x] = bgIsDefault ? nil : bg
            }

            // Backgrounds: merge runs of equal color.
            var x = 0
            while x < n {
                guard let bg = bgs[x] else { x += 1; continue }
                var e = x + 1
                while e < n, bgs[e] == bg { e += 1 }
                ctx.setFillColor(bg.cgColor)
                // extend edge cells into padding so full-width bars look seamless
                let x0 = x == 0 ? 0 : padX + CGFloat(x) * cellW
                let x1 = e == s.cols ? bounds.width : padX + CGFloat(e) * cellW
                ctx.fill(CGRect(x: x0, y: y, width: x1 - x0, height: cellH))
                x = e
            }

            // Text: batch runs of plain ASCII with identical style; draw others per cell.
            x = 0
            while x < n {
                let c = row.cells[x]
                if c.width == 0 || c.ch == " " { x += 1; continue }
                let style = fontIndex(c.attrs)
                let cx = padX + CGFloat(x) * cellW
                if let a = c.ch.asciiValue, a > 0x20 {
                    var e = x + 1
                    var str = String(c.ch)
                    while e < n, let b = row.cells[e].ch.asciiValue, b >= 0x20, row.cells[e].width == 1,
                          fgs[e] == fgs[x], fontIndex(row.cells[e].attrs) == style {
                        str.append(row.cells[e].ch); e += 1
                    }
                    drawText(ctx, str, font: fonts[style], color: fgs[x], x: cx, y: y)
                    x = e
                } else {
                    let rect = CGRect(x: cx, y: y, width: cellW * CGFloat(max(1, c.width)), height: cellH)
                    if !drawSprite(ctx, c.ch, rect: rect, color: fgs[x]) {
                        drawCentered(ctx, String(c.ch), font: fonts[style], color: fgs[x], rect: rect)
                    }
                    x += 1
                }
            }

            // Decorations
            for x in 0..<n {
                let c = row.cells[x]
                let cx = padX + CGFloat(x) * cellW
                let lw = max(1, round(fontSize / 13))
                ctx.setStrokeColor(fgs[x].cgColor); ctx.setLineWidth(lw)
                if c.attrs.contains(.underline) || c.link != 0 && isHoveredLink(c.link, row: r) {
                    line(ctx, cx, y + ascent + 2, cx + cellW, y + ascent + 2)
                }
                if c.attrs.contains(.doubleUnderline) {
                    line(ctx, cx, y + ascent + 1.5, cx + cellW, y + ascent + 1.5)
                    line(ctx, cx, y + ascent + 3.5, cx + cellW, y + ascent + 3.5)
                }
                if c.attrs.contains(.curlyUnderline) {
                    let p = CGMutablePath(); let by = y + ascent + 2.5
                    p.move(to: CGPoint(x: cx, y: by))
                    p.addCurve(to: CGPoint(x: cx + cellW, y: by), control1: CGPoint(x: cx + cellW / 3, y: by - 2), control2: CGPoint(x: cx + 2 * cellW / 3, y: by + 2))
                    ctx.addPath(p); ctx.strokePath()
                }
                if c.attrs.contains(.strike) { line(ctx, cx, y + cellH / 2, cx + cellW, y + cellH / 2) }
                if c.attrs.contains(.overline) { line(ctx, cx, y + 0.5, cx + cellW, y + 0.5) }
            }
        }

        drawBookmarks(ctx, firstStable: s.firstStable, rows: s.rows.count)
        drawCursor(ctx, s)
        drawPreedit(ctx, s)
        drawUnfocusedDim(ctx, bg: defaultBG)
        drawHints(ctx)
        drawToast(ctx)

        if exited && config.waitAfterCommand == false { /* window will close */ }
        if Date() < flashUntil {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor); ctx.fill(bounds)
        }
        drawScrollIndicator(ctx)
    }

    private func fontIndex(_ a: CellAttrs) -> Int { (a.contains(.bold) ? 1 : 0) + (a.contains(.italic) ? 2 : 0) }

    private func line(_ ctx: CGContext, _ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
        ctx.move(to: CGPoint(x: x0, y: y0)); ctx.addLine(to: CGPoint(x: x1, y: y1)); ctx.strokePath()
    }

    private func drawText(_ ctx: CGContext, _ s: String, font: CTFont, color: RGB, x: CGFloat, y: CGFloat) {
        let k = fonts.firstIndex(where: { $0 === font }).map { kerns[$0] } ?? 0
        let attr = NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
            NSAttributedString.Key(kCTKernAttributeName as String): k,
        ])
        let lineRef = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: x, y: y + ascent)
        CTLineDraw(lineRef, ctx)
    }

    /// Non-ASCII glyphs (often from fallback fonts) are centered in their 1- or 2-cell slot.
    private func drawCentered(_ ctx: CGContext, _ str: String, font: CTFont, color: RGB, rect: CGRect) {
        let attr = NSAttributedString(string: str, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ])
        let l = CTLineCreateWithAttributedString(attr)
        let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
        ctx.textPosition = CGPoint(x: rect.minX + max(0, (rect.width - w) / 2), y: rect.minY + ascent)
        CTLineDraw(l, ctx)
    }

    /// Pixel-perfect box drawing & block elements (Ghostty renders these as
    /// sprites in src/font/sprite so lines join seamlessly across cells).
    private func drawSprite(_ ctx: CGContext, _ ch: Character, rect r: CGRect, color: RGB) -> Bool {
        guard let v = ch.unicodeScalars.first?.value, ch.unicodeScalars.count == 1 else { return false }
        ctx.setFillColor(color.cgColor)
        let light = max(1, round(fontSize / 13)), heavy = light * 2
        let mx = round(r.midX), my = round(r.midY)
        // (up, down, left, right) weights: 0 none, 1 light, 2 heavy
        let box: [UInt32: (Int, Int, Int, Int)] = [
            0x2500: (0, 0, 1, 1), 0x2501: (0, 0, 2, 2), 0x2502: (1, 1, 0, 0), 0x2503: (2, 2, 0, 0),
            0x250C: (0, 1, 0, 1), 0x250F: (0, 2, 0, 2), 0x2510: (0, 1, 1, 0), 0x2513: (0, 2, 2, 0),
            0x2514: (1, 0, 0, 1), 0x2517: (2, 0, 0, 2), 0x2518: (1, 0, 1, 0), 0x251B: (2, 0, 2, 0),
            0x251C: (1, 1, 0, 1), 0x2523: (2, 2, 0, 2), 0x2524: (1, 1, 1, 0), 0x252B: (2, 2, 2, 0),
            0x252C: (0, 1, 1, 1), 0x2533: (0, 2, 2, 2), 0x2534: (1, 0, 1, 1), 0x253B: (2, 0, 2, 2),
            0x253C: (1, 1, 1, 1), 0x254B: (2, 2, 2, 2), 0x2574: (0, 0, 1, 0), 0x2575: (1, 0, 0, 0),
            0x2576: (0, 0, 0, 1), 0x2577: (0, 1, 0, 0),
        ]
        if let (u, d, l, rt) = box[v] {
            func w(_ k: Int) -> CGFloat { k == 2 ? heavy : light }
            let hw = max(w(l), w(rt)), vw = max(w(u), w(d))
            if l > 0 { ctx.fill(CGRect(x: r.minX, y: my - w(l) / 2, width: mx - r.minX + vw / 2, height: w(l))) }
            if rt > 0 { ctx.fill(CGRect(x: mx - vw / 2, y: my - w(rt) / 2, width: r.maxX - mx + vw / 2, height: w(rt))) }
            if u > 0 { ctx.fill(CGRect(x: mx - w(u) / 2, y: r.minY, width: w(u), height: my - r.minY + hw / 2)) }
            if d > 0 { ctx.fill(CGRect(x: mx - w(d) / 2, y: my - hw / 2, width: w(d), height: r.maxY - my + hw / 2)) }
            return true
        }
        switch v {
        case 0x256D, 0x256E, 0x256F, 0x2570: // rounded corners ╭╮╯╰
            let p = CGMutablePath()
            let rad = min(r.width, r.height) / 2
            switch v {
            case 0x256D: p.move(to: CGPoint(x: mx, y: r.maxY)); p.addArc(tangent1End: CGPoint(x: mx, y: my), tangent2End: CGPoint(x: r.maxX, y: my), radius: rad); p.addLine(to: CGPoint(x: r.maxX, y: my))
            case 0x256E: p.move(to: CGPoint(x: mx, y: r.maxY)); p.addArc(tangent1End: CGPoint(x: mx, y: my), tangent2End: CGPoint(x: r.minX, y: my), radius: rad); p.addLine(to: CGPoint(x: r.minX, y: my))
            case 0x256F: p.move(to: CGPoint(x: mx, y: r.minY)); p.addArc(tangent1End: CGPoint(x: mx, y: my), tangent2End: CGPoint(x: r.minX, y: my), radius: rad); p.addLine(to: CGPoint(x: r.minX, y: my))
            default: p.move(to: CGPoint(x: mx, y: r.minY)); p.addArc(tangent1End: CGPoint(x: mx, y: my), tangent2End: CGPoint(x: r.maxX, y: my), radius: rad); p.addLine(to: CGPoint(x: r.maxX, y: my))
            }
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(light); ctx.addPath(p); ctx.strokePath()
            return true
        case 0x2580: ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: round(r.height / 2))); return true
        case 0x2581...0x2588: // lower 1/8 .. full block
            let h = round(r.height * CGFloat(v - 0x2580) / 8)
            ctx.fill(CGRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)); return true
        case 0x2589...0x258F: // left 7/8 .. 1/8
            let w = round(r.width * CGFloat(0x2590 - v) / 8)
            ctx.fill(CGRect(x: r.minX, y: r.minY, width: w, height: r.height)); return true
        case 0x2590: ctx.fill(CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height)); return true
        case 0x2591, 0x2592, 0x2593:
            ctx.setFillColor(color.nsColor.withAlphaComponent(CGFloat(v - 0x2590) * 0.25).cgColor)
            ctx.fill(r); return true
        case 0x2594: ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: round(r.height / 8))); return true
        case 0x2595: ctx.fill(CGRect(x: r.maxX - round(r.width / 8), y: r.minY, width: round(r.width / 8), height: r.height)); return true
        default: return false
        }
    }

    private func drawCursor(_ ctx: CGContext, _ s: Snapshot) {
        guard let (cx, cy) = s.cursor, markedText.length == 0 else { return }
        let focused = isFocused
        if focused && terminal.cursorBlink && !blinkOn { return }
        let w = cellW * (s.cursorWide ? 2 : 1)
        let rect = CGRect(x: padX + CGFloat(cx) * cellW, y: padY + CGFloat(cy) * cellH, width: w, height: cellH)
        drawTrail(ctx, to: rect, color: s.cursorColor)
        ctx.setFillColor(s.cursorColor.cgColor)
        ctx.setStrokeColor(s.cursorColor.cgColor)
        if !focused {
            ctx.setLineWidth(1); ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5)); return
        }
        switch s.cursorShape {
        case .block:
            ctx.fill(rect)
            let row = s.rows[cy]
            if cx < row.cells.count, row.cells[cx].ch != " ", row.cells[cx].width != 0 {
                let c = row.cells[cx]
                if !drawSprite(ctx, c.ch, rect: rect, color: s.bg) {
                    drawText(ctx, String(c.ch), font: fonts[fontIndex(c.attrs)], color: s.bg, x: rect.minX, y: rect.minY)
                }
            }
        case .bar: ctx.fill(CGRect(x: rect.minX, y: rect.minY, width: max(2, round(fontSize / 8)), height: cellH))
        case .underline: ctx.fill(CGRect(x: rect.minX, y: rect.maxY - 2, width: w, height: 2))
        }
    }

    private func drawPreedit(_ ctx: CGContext, _ s: Snapshot) {
        guard markedText.length > 0, let (cx, cy) = s.cursor else { return }
        let x = padX + CGFloat(cx) * cellW, y = padY + CGFloat(cy) * cellH
        let str = markedText.string
        let width = CGFloat(str.unicodeScalars.reduce(0) { $0 + max(1, CharWidth.of($1)) }) * cellW
        ctx.setFillColor(s.bg.cgColor); ctx.fill(CGRect(x: x, y: y, width: width, height: cellH))
        drawText(ctx, str, font: fonts[0], color: s.fg, x: x, y: y)
        ctx.setStrokeColor(s.fg.cgColor); ctx.setLineWidth(1)
        line(ctx, x, y + cellH - 1, x + width, y + cellH - 1)
    }

    private func drawScrollIndicator(_ ctx: CGContext) {
        terminal.lock.lock()
        let off = terminal.scrollOffset, total = terminal.totalLines, rows = terminal.rows
        terminal.lock.unlock()
        guard off > 0, total > rows else { return }
        let h = max(20, bounds.height * CGFloat(rows) / CGFloat(total))
        let top = (bounds.height - h) * (1 - CGFloat(off) / CGFloat(total - rows))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: bounds.width - 6, y: top, width: 4, height: h), cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.fillPath()
    }

    // MARK: - Process lifecycle

    private func processExited(_ code: Int32) {
        exited = true
        exitCode = code
        if config.waitAfterCommand {
            terminal.lock.lock()
            terminal.feed("\r\n\u{1B}[2m[Process exited with code \(code). Press any key to close.]\u{1B}[0m")
            terminal.lock.unlock()
            needsDisplay = true
        } else if ProcessInfo.processInfo.environment["MANTIS_SNAPSHOT"] == nil {
            onClose?(self)
        }
    }

    private func bell() {
        flashUntil = Date().addingTimeInterval(0.12)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.needsDisplay = true }
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        blinkOn = true
        sendFocus(true)
        onFocus?(self)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        sendFocus(false)
        needsDisplay = true
        return true
    }

    private func sendFocus(_ on: Bool) {
        terminal.lock.lock(); let f = terminal.modes.focusEvents; terminal.lock.unlock()
        if f { pty.write(Array((on ? "\u{1B}[I" : "\u{1B}[O").utf8)) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.contentResizeIncrements = NSSize(width: cellW, height: cellH)
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.needsDisplay = true }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.needsDisplay = true }
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.iBeam.set() }

    // MARK: - Keyboard

    private func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        terminal.lock.lock(); terminal.scrollToBottom(); terminal.lock.unlock()
        if selection != nil { selection = nil }
        blinkOn = true
        pty.write(bytes)
        needsDisplay = true
    }

    private func mods(_ f: NSEvent.ModifierFlags) -> KeyMods {
        var m: KeyMods = []
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.option) { m.insert(.alt) }
        if f.contains(.control) { m.insert(.ctrl) }
        if f.contains(.command) { m.insert(.cmd) }
        return m
    }

    private static let specialKeys: [UInt16: SpecialKey] = [
        36: .enter, 76: .enter, 48: .tab, 51: .backspace, 53: .escape, 117: .forwardDelete, 114: .insert,
        123: .left, 124: .right, 125: .down, 126: .up, 115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
        122: .f(1), 120: .f(2), 99: .f(3), 118: .f(4), 96: .f(5), 97: .f(6), 98: .f(7), 100: .f(8),
        101: .f(9), 109: .f(10), 103: .f(11), 111: .f(12),
    ]

    override func keyDown(with event: NSEvent) {
        if exited && config.waitAfterCommand { onClose?(self); return }
        if config.mouseHideWhileTyping { NSCursor.setHiddenUntilMouseMoves(true) }

        if hintActive { handleHintKey(event); return }

        // While composing (IME), all keys belong to the input method.
        if hasMarkedText() { interpretKeyEvents([event]); return }

        let m = mods(event.modifierFlags)
        terminal.lock.lock(); let appCursor = terminal.modes.appCursorKeys; terminal.lock.unlock()

        if let key = Self.specialKeys[event.keyCode] {
            // Shift+PageUp/Down scroll the viewport instead of reaching the app.
            if m == .shift, key == .pageUp || key == .pageDown {
                terminal.lock.lock(); terminal.scrollViewport(by: (key == .pageUp ? 1 : -1) * (terminal.rows - 1)); terminal.lock.unlock()
                needsDisplay = true; return
            }
            // Option+←/→ = word jump (readline/zsh), matching macOS terminal conventions.
            if m == .alt && !config.optionAsAlt, key == .left || key == .right {
                send(key == .left ? [0x1B, 0x62] : [0x1B, 0x66]); return
            }
            send(KeyEncoder.encode(key, mods: m.subtracting(.cmd), appCursor: appCursor))
            return
        }

        if m.contains(.ctrl), let ch = event.charactersIgnoringModifiers?.first, let b = KeyEncoder.control(ch) {
            send((m.contains(.alt) ? [0x1B] : []) + [b]); return
        }

        if m.contains(.alt) && config.optionAsAlt, let s = event.charactersIgnoringModifiers {
            send([0x1B] + Array(s.utf8)); return
        }

        interpretKeyEvents([event]) // → insertText / setMarkedText (dead keys, IME)
    }

    override func doCommand(by selector: Selector) { /* handled in keyDown */ }

    // NSTextInputClient
    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = NSMutableAttributedString()
        send(Array(s.utf8))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: a) }
        else if let s = string as? String { markedText = NSMutableAttributedString(string: s) }
        needsDisplay = true
    }

    func unmarkText() { markedText = NSMutableAttributedString(); needsDisplay = true }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let w = window else { return .zero }
        return w.convertToScreen(convert(cursorRect, to: nil))
    }

    // MARK: - Mouse

    private func cell(at event: NSEvent) -> (col: Int, row: Int) {
        let p = convert(event.locationInWindow, from: nil)
        terminal.lock.lock(); defer { terminal.lock.unlock() }
        let col = max(0, min(terminal.cols - 1, Int((p.x - padX) / cellW)))
        let row = max(0, min(terminal.rows - 1, Int((p.y - padY) / cellH)))
        return (col, row)
    }

    /// Returns true if the event was forwarded to the application (mouse reporting).
    private func reportMouse(_ event: NSEvent, button: MouseButton, pressed: Bool, motion: Bool) -> Bool {
        terminal.lock.lock()
        let tracking = terminal.modes.mouseTracking, sgr = terminal.modes.mouseSGR
        terminal.lock.unlock()
        guard tracking != .none, !event.modifierFlags.contains(.shift) else { return false }
        if motion {
            if tracking == .normal || tracking == .x10 { return true }
            if tracking == .button && button == .none { return true }
        }
        if !pressed && tracking == .x10 { return true }
        let (c, r) = cell(at: event)
        if motion, let last = lastMouseCell, last == (c, r) { return true }
        lastMouseCell = (c, r)
        pty.write(MouseEncoder.encode(button: button, x: c, y: r, pressed: pressed, motion: motion, mods: mods(event.modifierFlags), sgr: sgr))
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.command), commandClick(event) { return }
        if reportMouse(event, button: .left, pressed: true, motion: false) { return }
        let (c, r) = cell(at: event)
        terminal.lock.lock()
        let p = terminal.stablePoint(viewportRow: r, col: c)
        switch event.clickCount {
        case 2: selection = terminal.wordSelection(at: p)
        case 3: selection = terminal.lineSelection(at: p)
        default:
            selection = nil
            selecting = true
            pendingAnchor = p
        }
        terminal.lock.unlock()
        if event.clickCount >= 2 { selectionFinished() }
        needsDisplay = true
    }

    private var pendingAnchor: GridPoint?

    override func mouseDragged(with event: NSEvent) {
        if reportMouse(event, button: .left, pressed: true, motion: true) { return }
        guard selecting, let anchor = pendingAnchor else { return }
        // Auto-scroll when dragging outside the view.
        let p = convert(event.locationInWindow, from: nil)
        terminal.lock.lock()
        if p.y < 0 { terminal.scrollViewport(by: 1) } else if p.y > bounds.height { terminal.scrollViewport(by: -1) }
        terminal.lock.unlock()
        let (c, r) = cell(at: event)
        terminal.lock.lock()
        let head = terminal.stablePoint(viewportRow: r, col: c)
        terminal.lock.unlock()
        var s = Selection(anchor: anchor, head: head)
        s.rectangular = event.modifierFlags.contains(.option)
        selection = s
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if reportMouse(event, button: .left, pressed: false, motion: false) { return }
        if selecting { selecting = false; selectionFinished() }
    }

    override func mouseMoved(with event: NSEvent) {
        _ = reportMouse(event, button: .none, pressed: true, motion: true)
        let cmd = event.modifierFlags.contains(.command)
        if cmd != hoverCmd { hoverCmd = cmd; needsDisplay = true }
        if cmd { hoverRow = cell(at: event).row; needsDisplay = true }
    }

    private var hoverCmd = false
    private var hoverRow = -1
    private func isHoveredLink(_ id: UInt16, row: Int) -> Bool { hoverCmd && row == hoverRow }

    override func flagsChanged(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        if cmd != hoverCmd { hoverCmd = cmd; needsDisplay = true }
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportMouse(event, button: .right, pressed: true, motion: false) { return }
        super.rightMouseDown(with: event)
    }
    override func rightMouseUp(with event: NSEvent) { _ = reportMouse(event, button: .right, pressed: false, motion: false) }
    override func otherMouseDown(with event: NSEvent) { _ = reportMouse(event, button: .middle, pressed: true, motion: false) }
    override func otherMouseUp(with event: NSEvent) { _ = reportMouse(event, button: .middle, pressed: false, motion: false) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Split Right", action: #selector(TerminalWindowController.splitRight(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Split Down", action: #selector(TerminalWindowController.splitDown(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Clear", action: #selector(clearBuffer(_:)), keyEquivalent: "")
        return m
    }

    private func selectionFinished() {
        if config.copyOnSelect, selection != nil { copy(nil) }
    }

    override func scrollWheel(with event: NSEvent) {
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { dy /= cellH } else { dy *= 3 }
        scrollAccum += dy
        let lines = Int(scrollAccum)
        guard lines != 0 else { return }
        scrollAccum -= CGFloat(lines)

        terminal.lock.lock()
        let tracking = terminal.modes.mouseTracking
        let altScroll = terminal.modes.altScreen && terminal.modes.alternateScroll
        let appCursor = terminal.modes.appCursorKeys
        terminal.lock.unlock()

        if tracking != .none && !event.modifierFlags.contains(.shift) {
            for _ in 0..<min(abs(lines), 10) {
                _ = reportMouse(event, button: lines > 0 ? .wheelUp : .wheelDown, pressed: true, motion: false)
            }
        } else if altScroll {
            // less/vim without mouse mode: translate wheel into arrow keys (xterm alternateScroll).
            let key: SpecialKey = lines > 0 ? .up : .down
            for _ in 0..<min(abs(lines), 10) { pty.write(KeyEncoder.encode(key, mods: [], appCursor: appCursor)) }
        } else {
            terminal.lock.lock(); terminal.scrollViewport(by: lines); terminal.lock.unlock()
            needsDisplay = true
        }
    }

    func openLink(at event: NSEvent) -> Bool {
        let (c, r) = cell(at: event)
        terminal.lock.lock()
        let row = terminal.viewportRow(r)
        let linkID = c < row.cells.count ? Int(row.cells[c].link) : 0
        let explicit = linkID > 0 && linkID < terminal.hyperlinks.count ? terminal.hyperlinks[linkID] : nil
        terminal.lock.unlock()
        if let explicit, let url = URL(string: explicit) { NSWorkspace.shared.open(url); return true }
        // Fall back to detecting a plain-text URL under the cursor.
        let text = row.text
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return false }
        let chars = Array(text)
        for m in det.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(m.range, in: text) else { continue }
            let lo = text.distance(from: text.startIndex, to: range.lowerBound)
            let hi = text.distance(from: text.startIndex, to: range.upperBound)
            // map grapheme offsets to cell columns (account for wide cells)
            var col = 0, cLo = 0, cHi = 0
            for (i, _) in chars.enumerated() {
                if i == lo { cLo = col }
                if i == hi { cHi = col; break }
                col += 1
                while col < row.cells.count && row.cells[col].width == 0 { col += 1 }
            }
            if hi >= chars.count { cHi = row.cells.count }
            if c >= cLo && c < cHi, let url = m.url { NSWorkspace.shared.open(url); return true }
        }
        return false
    }

    // MARK: - Actions (menu)

    @objc func copy(_ sender: Any?) {
        guard let sel = selection else { return }
        terminal.lock.lock(); let text = terminal.text(in: sel); terminal.lock.unlock()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        terminal.lock.lock(); let bracketed = terminal.modes.bracketedPaste; terminal.lock.unlock()
        if config.confirmUnsafePaste && KeyEncoder.isUnsafePaste(text, bracketed: bracketed) {
            presentPastePreview(text, bracketed: bracketed)
        } else { sendPaste(text, bracketed: bracketed) }
    }

    func sendPaste(_ text: String, bracketed: Bool) { send(KeyEncoder.paste(text, bracketed: bracketed)) }

    @objc override func selectAll(_ sender: Any?) {
        terminal.lock.lock()
        selection = Selection(anchor: GridPoint(line: terminal.droppedLines, col: 0),
                              head: GridPoint(line: terminal.droppedLines + terminal.totalLines - 1, col: terminal.cols - 1))
        terminal.lock.unlock()
        needsDisplay = true
    }

    @objc func clearBuffer(_ sender: Any?) {
        terminal.lock.lock(); terminal.clearScreenAndHistory(); terminal.lock.unlock()
        pty.write([0x0C]) // ^L so the shell redraws its prompt
        selection = nil
        needsDisplay = true
    }

    @objc func increaseFontSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc func decreaseFontSize(_ sender: Any?) { setFontSize(max(6, fontSize - 1)) }
    @objc func resetFontSize(_ sender: Any?) { setFontSize(config.fontSize) }

    private func setFontSize(_ s: CGFloat) {
        fontSize = s
        updateFonts()
        updateGrid()
    }

    @objc func scrollToTop(_ sender: Any?) {
        terminal.lock.lock(); terminal.scrollViewport(by: terminal.totalLines); terminal.lock.unlock(); needsDisplay = true
    }
    @objc func scrollToBottomAction(_ sender: Any?) {
        terminal.lock.lock(); terminal.scrollToBottom(); terminal.lock.unlock(); needsDisplay = true
    }

    // MARK: - Search

    @objc func showFind(_ sender: Any?) {
        if let f = searchField { window?.makeFirstResponder(f); return }
        let f = NSSearchField(frame: NSRect(x: bounds.width - 260, y: 8, width: 250, height: 24))
        f.autoresizingMask = [.minXMargin]
        f.placeholderString = "Find (↩ next, ⇧↩ prev, esc close)"
        f.target = self
        f.action = #selector(searchChanged(_:))
        f.sendsSearchStringImmediately = true
        f.delegate = self
        addSubview(f)
        searchField = f
        window?.makeFirstResponder(f)
    }

    @objc private func searchChanged(_ sender: NSSearchField) { runSearch(); jumpToMatch() }

    private func runSearch() {
        let q = searchField?.stringValue ?? ""
        terminal.lock.lock(); searchMatches = terminal.search(q); terminal.lock.unlock()
        searchIndex = max(0, searchMatches.count - 1) // start at the most recent match
        needsDisplay = true
    }

    private func jumpToMatch() {
        guard searchMatches.indices.contains(searchIndex) else { return }
        let m = searchMatches[searchIndex]
        terminal.lock.lock()
        let abs = m.anchor.line - terminal.droppedLines
        let top = terminal.absIndex(viewportRow: 0)
        if abs < top || abs >= top + terminal.rows {
            let desired = terminal.scrollback.count - (abs - terminal.rows / 2)
            terminal.scrollOffset = max(0, min(terminal.scrollback.count, desired))
        }
        terminal.lock.unlock()
        needsDisplay = true
    }

    @objc func findNext(_ sender: Any?) {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + 1) % searchMatches.count; jumpToMatch()
    }

    @objc func findPrevious(_ sender: Any?) {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex - 1 + searchMatches.count) % searchMatches.count; jumpToMatch()
    }

    private func closeFind() {
        searchField?.removeFromSuperview()
        searchField = nil
        searchMatches = []
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Snapshot (headless verification)

    func writeSnapshot(to path: String) -> Bool {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}

extension TerminalView: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.shift) { findPrevious(nil) } else { findNext(nil) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeFind(); return true
        default: return false
        }
    }
}
