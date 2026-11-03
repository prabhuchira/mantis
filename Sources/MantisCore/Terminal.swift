import Foundation

/// Terminal state: screens, cursor, modes, scrollback — fed by the Parser.
/// Equivalent of Ghostty's `src/terminal/Terminal.zig` + `Screen.zig`.
/// Not thread-safe by itself: callers hold `lock` (Ghostty uses a renderer
/// state mutex shared between the IO thread and the renderer thread the same way).
public final class Terminal: ASCIIRunHandler {
    public enum CursorShape: Equatable { case block, underline, bar }
    public enum MouseTracking: Equatable { case none, x10, normal, button, any }
    enum Charset { case ascii, decSpecial }

    public struct Modes {
        public var autowrap = true
        public var originMode = false
        public var insertMode = false
        public var appCursorKeys = false
        public var appKeypad = false
        public var bracketedPaste = false
        public var cursorVisible = true
        public var altScreen = false
        public var mouseTracking: MouseTracking = .none
        public var mouseSGR = false
        public var focusEvents = false
        public var synchronizedOutput = false
        public var alternateScroll = true
        public var reverseVideo = false
    }

    struct Pen { var fg: TermColor = .default; var bg: TermColor = .default; var attrs: CellAttrs = []; var link: UInt16 = 0 }

    struct SavedCursor {
        var x = 0, y = 0
        var pen = Pen()
        var originMode = false
        var pendingWrap = false
        var charsets: [Charset] = [.ascii, .ascii]
        var gl = 0
    }

    public let lock = NSLock()
    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var lines: [Row]
    private var primaryLines: [Row]? // saved primary screen while alt screen active
    public private(set) var scrollback: RingBuffer<Row>
    /// Total lines ever evicted from scrollback; gives stable line numbers for selections.
    public private(set) var droppedLines = 0
    /// How many lines the viewport is scrolled up into history (0 = bottom).
    public var scrollOffset = 0

    public private(set) var cursorX = 0
    public private(set) var cursorY = 0
    var pendingWrap = false
    var pen = Pen()
    var saved = SavedCursor()
    var savedAlt = SavedCursor()
    public private(set) var scrollTop = 0
    public private(set) var scrollBottom: Int
    var tabstops: [Bool]
    public var modes = Modes()
    public var cursorShape: CursorShape = .block
    public var cursorBlink = true
    public private(set) var title = ""
    public private(set) var workingDirectory: String?
    public private(set) var hyperlinks: [String] = [""]
    var charsets: [Charset] = [.ascii, .ascii]
    var gl = 0
    var lastPrinted: Character?
    /// Bumped every time the visible content may have changed (renderer dirty check).
    public private(set) var generation: UInt64 = 0

    public var palette: [RGB] = Palette.make256()
    public var defaultFG = RGB(0xD6, 0xDA, 0xE3)
    public var defaultBG = RGB(0x14, 0x16, 0x1B)
    public var cursorColor = RGB(0xF2, 0xC1, 0x4E)

    // Side effects flow out through callbacks (Ghostty: stream_handler.zig → surface messages).
    public var onResponse: (([UInt8]) -> Void)?
    public var onTitle: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
    public var onWorkingDirectory: ((String) -> Void)?
    public var onNotification: ((String, String) -> Void)?

    private let parser = Parser()

    public init(cols: Int = 80, rows: Int = 24, scrollbackLimit: Int = 10_000) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        lines = Array(repeating: Row(cols: max(1, cols)), count: max(1, rows))
        scrollback = RingBuffer(capacity: scrollbackLimit)
        scrollBottom = max(1, rows) - 1
        tabstops = Terminal.defaultTabs(max(1, cols))
        parser.handler = self
    }

    static func defaultTabs(_ cols: Int) -> [Bool] { (0..<cols).map { $0 % 8 == 0 && $0 != 0 } }

    // MARK: - Input

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ buffer: UnsafeBufferPointer<UInt8>) {
        let sbBefore = scrollback.count &+ droppedLines
        parser.feed(buffer)
        generation &+= 1
        // Keep a scrolled-back viewport pinned to the same content (like Ghostty).
        if scrollOffset > 0 {
            let added = (scrollback.count &+ droppedLines) - sbBefore
            scrollOffset = max(0, min(scrollOffset + added, scrollback.count))
        }
    }

    public func feed(_ s: String) { feed(Array(s.utf8)) }

    // MARK: - Viewport access

    public var totalLines: Int { scrollback.count + rows }

    /// Line by absolute index (0 = oldest retained scrollback line).
    public func line(at idx: Int) -> Row {
        if idx < scrollback.count { return scrollback[idx] }
        return lines[idx - scrollback.count]
    }

    /// Absolute index of viewport row `r`.
    public func absIndex(viewportRow r: Int) -> Int { scrollback.count - scrollOffset + r }

    public func viewportRow(_ r: Int) -> Row { line(at: absIndex(viewportRow: r)) }

    public func scrollViewport(by delta: Int) {
        scrollOffset = max(0, min(scrollback.count, scrollOffset + delta))
        generation &+= 1
    }

    public func scrollToBottom() {
        if scrollOffset != 0 { scrollOffset = 0; generation &+= 1 }
    }

    // MARK: - Resize

    public func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(1, newCols), newRows = max(1, newRows)
        guard newCols != cols || newRows != rows else { return }

        func fit(_ r: inout Row) {
            if r.cells.count > newCols {
                r.cells.removeLast(r.cells.count - newCols)
                if let last = r.cells.last, last.width == 2 { r.cells[newCols - 1] = Cell() }
            } else if r.cells.count < newCols {
                r.cells.append(contentsOf: repeatElement(Cell(), count: newCols - r.cells.count))
            }
        }

        let onPrimary = !modes.altScreen
        // Shrinking rows: push top lines into scrollback so the cursor stays visible.
        if newRows < rows {
            let excess = max(0, cursorY - (newRows - 1))
            if excess > 0 {
                for _ in 0..<excess {
                    let r = lines.removeFirst()
                    if onPrimary { pushScrollback(r) }
                }
                cursorY -= excess
            }
            if lines.count > newRows { lines.removeLast(lines.count - newRows) }
        } else if newRows > rows {
            // Growing: pull lines back out of scrollback first (primary screen only).
            var add = newRows - rows
            if onPrimary {
                while add > 0 && scrollback.count > 0 {
                    lines.insert(scrollback.removeLast(), at: 0)
                    cursorY += 1
                    add -= 1
                }
            }
            for _ in 0..<add { lines.append(Row(cols: newCols)) }
        }
        for i in lines.indices { fit(&lines[i]) }
        if var p = primaryLines {
            while p.count > newRows { p.removeFirst() }
            while p.count < newRows { p.append(Row(cols: newCols)) }
            for i in p.indices { fit(&p[i]) }
            primaryLines = p
        }

        cols = newCols
        rows = newRows
        scrollTop = 0
        scrollBottom = newRows - 1
        tabstops = Terminal.defaultTabs(newCols)
        cursorX = min(cursorX, newCols - 1)
        cursorY = min(max(0, cursorY), newRows - 1)
        pendingWrap = false
        scrollOffset = min(scrollOffset, scrollback.count)
        generation &+= 1
    }

    // MARK: - ParserHandler

    public func print(_ scalarIn: Unicode.Scalar) {
        var scalar = scalarIn
        if charsets[gl] == .decSpecial, let m = Terminal.decSpecialMap[scalar.value] { scalar = m }
        let w = CharWidth.of(scalar)

        if w == 0 {
            // Combining mark / ZWJ / variation selector: attach to the previous cell.
            var x = pendingWrap ? cursorX : cursorX - 1
            guard x >= 0 else { return }
            if lines[cursorY].cells[x].width == 0, x > 0 { x -= 1 }
            var s = String(lines[cursorY].cells[x].ch)
            s.unicodeScalars.append(scalar)
            if s.count == 1 { lines[cursorY].cells[x].ch = Character(s) }
            if scalar.value == 0xFE0F, lines[cursorY].cells[x].width == 1, x + 1 < cols, !pendingWrap {
                // VS16 makes the base an emoji presentation (wide) glyph.
                lines[cursorY].cells[x].width = 2
                lines[cursorY].cells[x + 1] = Cell(bg: lines[cursorY].cells[x].bg, width: 0)
                cursorX = min(cursorX + 1, cols - 1)
                if x + 2 >= cols { pendingWrap = modes.autowrap; cursorX = cols - 1 }
            }
            return
        }

        if pendingWrap && modes.autowrap {
            lines[cursorY].wrapped = true
            cursorX = 0
            index()
        }
        pendingWrap = false

        if w == 2 && cursorX == cols - 1 {
            guard modes.autowrap, cols > 1 else { return }
            lines[cursorY].cells[cursorX] = blankCell()
            lines[cursorY].wrapped = true
            cursorX = 0
            index()
        }

        if modes.insertMode {
            let row = cursorY
            lines[row].cells.insert(contentsOf: repeatElement(blankCell(), count: w), at: cursorX)
            lines[row].cells.removeLast(w)
        }

        clearWide(row: cursorY, col: cursorX)
        if w == 2 { clearWide(row: cursorY, col: cursorX + 1) }

        let ch = Character(scalar)
        lines[cursorY].cells[cursorX] = Cell(ch: ch, fg: pen.fg, bg: pen.bg, attrs: pen.attrs, width: UInt8(w), link: pen.link)
        if w == 2 {
            lines[cursorY].cells[cursorX + 1] = Cell(fg: pen.fg, bg: pen.bg, attrs: pen.attrs, width: 0, link: pen.link)
        }
        lastPrinted = ch

        if cursorX + w >= cols {
            cursorX = cols - 1
            pendingWrap = modes.autowrap
        } else {
            cursorX += w
        }
    }

    static let asciiChars: [Character] = (0..<128).map { Character(Unicode.Scalar(UInt8($0))) }

    /// Batched print for printable ASCII (no width lookup, no combining, in-place row writes).
    public func printASCII(_ run: UnsafeBufferPointer<UInt8>) {
        if charsets[gl] != .ascii || modes.insertMode {
            for b in run { print(Unicode.Scalar(b)) }
            return
        }
        var i = 0
        let n = run.count
        while i < n {
            if pendingWrap && modes.autowrap {
                lines[cursorY].wrapped = true
                cursorX = 0
                index()
            }
            pendingWrap = false
            let count = min(n - i, cols - cursorX)
            let x0 = cursorX, x1 = cursorX + count - 1
            clearWide(row: cursorY, col: x0)
            if x1 != x0 || lines[cursorY].cells[x1].width == 2 { clearWide(row: cursorY, col: x1) }
            let template = Cell(ch: " ", fg: pen.fg, bg: pen.bg, attrs: pen.attrs, width: 1, link: pen.link)
            let table = Terminal.asciiChars
            lines[cursorY].cells.withUnsafeMutableBufferPointer { cells in
                var c = template
                for k in 0..<count {
                    c.ch = table[Int(run[i + k])]
                    cells[x0 + k] = c
                }
            }
            i += count
            if x1 >= cols - 1 {
                cursorX = cols - 1
                pendingWrap = modes.autowrap
                if !modes.autowrap && i < n { // without autowrap, the rest overwrites the last column
                    var c = template; c.ch = Terminal.asciiChars[Int(run[n - 1])]
                    lines[cursorY].cells[cols - 1] = c
                    i = n
                }
            } else {
                cursorX = x1 + 1
            }
        }
        lastPrinted = Terminal.asciiChars[Int(run[n - 1])]
    }

    public func execute(_ byte: UInt8) {
        switch byte {
        case 0x07: onBell?()
        case 0x08: // BS
            if pendingWrap { pendingWrap = false } else if cursorX > 0 { cursorX -= 1 }
        case 0x09: tab(1)
        case 0x0A, 0x0B, 0x0C: index()
        case 0x0D: cursorX = 0; pendingWrap = false
        case 0x0E: gl = 1 // SO
        case 0x0F: gl = 0 // SI
        default: break
        }
    }

    public func escDispatch(intermediates: [UInt8], final: UInt8) {
        if let i = intermediates.first {
            switch (i, final) {
            case (0x28, _): charsets[0] = final == 0x30 ? .decSpecial : .ascii // ESC ( X
            case (0x29, _): charsets[1] = final == 0x30 ? .decSpecial : .ascii // ESC ) X
            case (0x23, 0x38): // DECALN: fill screen with E
                for y in 0..<rows { lines[y] = Row(cells: Array(repeating: Cell(ch: "E"), count: cols)) }
                setCursor(x: 0, y: 0)
            default: break
            }
            return
        }
        switch final {
        case 0x37: saveCursor()                      // 7 DECSC
        case 0x38: restoreCursor()                   // 8 DECRC
        case 0x44: index()                           // D IND
        case 0x45: cursorX = 0; pendingWrap = false; index() // E NEL
        case 0x48: tabstops[cursorX] = true          // H HTS
        case 0x4D: reverseIndex()                    // M RI
        case 0x63: fullReset()                       // c RIS
        case 0x3D: modes.appKeypad = true            // =
        case 0x3E: modes.appKeypad = false           // >
        default: break
        }
    }

    public func csiDispatch(params: [[Int]], intermediates: [UInt8], final: UInt8) {
        func p(_ i: Int, _ def: Int = 0) -> Int {
            guard i < params.count else { return def }
            let v = params[i][0]
            return v == 0 ? def : v
        }
        let priv = intermediates.first
        let n = max(1, p(0, 1))

        // Private / intermediate-qualified sequences
        if let priv {
            switch (priv, final) {
            case (0x3F, 0x68): setPrivateModes(params, true); return    // ?h
            case (0x3F, 0x6C): setPrivateModes(params, false); return   // ?l
            case (0x3E, 0x63): respond("\u{1B}[>1;100;0c"); return      // secondary DA
            case (0x3E, 0x71): respond("\u{1B}P>|Mantis 0.1\u{1B}\\"); return // XTVERSION
            case (0x3F, 0x6E): // DECDSR
                if p(0) == 6 { respond("\u{1B}[?\(cursorY + 1);\(cursorX + 1)R") }
                return
            case (0x3F, 0x75): respond("\u{1B}[?0u"); return            // kitty kbd query: unsupported flags
            case (0x20, 0x71): // DECSCUSR  CSI Ps SP q
                switch p(0) {
                case 0, 1: cursorShape = .block; cursorBlink = true
                case 2: cursorShape = .block; cursorBlink = false
                case 3: cursorShape = .underline; cursorBlink = true
                case 4: cursorShape = .underline; cursorBlink = false
                case 5: cursorShape = .bar; cursorBlink = true
                case 6: cursorShape = .bar; cursorBlink = false
                default: break
                }
                return
            case (0x21, 0x70): softReset(); return                      // DECSTR CSI ! p
            case (0x24, 0x70): // DECRQM (ANSI) CSI Ps $ p — report not recognized
                respond("\u{1B}[\(p(0));0$y"); return
            default:
                if priv == 0x3F, intermediates.count > 1, intermediates[1] == 0x24, final == 0x70 {
                    let m = p(0)                                        // DECRQM private CSI ? Ps $ p
                    let v: Int
                    switch privateModeValue(m) { case .some(true): v = 1; case .some(false): v = 2; case .none: v = 0 }
                    respond("\u{1B}[?\(m);\(v)$y")
                }
                return
            }
        }

        switch final {
        case 0x40: insertChars(n)                                   // @ ICH
        case 0x41: setCursor(x: cursorX, y: max(cursorY - n, cursorY >= scrollTop ? scrollTop : 0)) // A CUU
        case 0x42, 0x65: setCursor(x: cursorX, y: min(cursorY + n, cursorY <= scrollBottom ? scrollBottom : rows - 1)) // B CUD, e VPR
        case 0x43, 0x61: setCursor(x: cursorX + n, y: cursorY)      // C CUF, a HPR
        case 0x44: setCursor(x: (pendingWrap ? cursorX : cursorX) - n, y: cursorY) // D CUB
        case 0x45: setCursor(x: 0, y: min(cursorY + n, scrollBottom)) // E CNL
        case 0x46: setCursor(x: 0, y: max(cursorY - n, scrollTop))  // F CPL
        case 0x47, 0x60: setCursor(x: p(0, 1) - 1, y: cursorY)      // G CHA, ` HPA
        case 0x48, 0x66: cup(row: p(0, 1), col: p(1, 1))            // H CUP, f HVP
        case 0x49: tab(n)                                           // I CHT
        case 0x4A: eraseDisplay(p(0))                               // J ED
        case 0x4B: eraseLine(p(0))                                  // K EL
        case 0x4C: insertLines(n)                                   // L IL
        case 0x4D: deleteLines(n)                                   // M DL
        case 0x50: deleteChars(n)                                   // P DCH
        case 0x53: scrollUp(n)                                      // S SU
        case 0x54: scrollDown(n)                                    // T SD
        case 0x58: eraseChars(n)                                    // X ECH
        case 0x5A: backTab(n)                                       // Z CBT
        case 0x62: if let c = lastPrinted { for _ in 0..<min(n, cols * rows) { print(c.unicodeScalars.first!) } } // b REP
        case 0x63: if p(0) == 0 { respond("\u{1B}[?62;22c") }      // c DA1
        case 0x64: cup(row: p(0, 1), col: cursorX + 1, ignoreOrigin: false) // d VPA
        case 0x67: // g TBC
            if p(0) == 0 { tabstops[cursorX] = false } else if p(0) == 3 { tabstops = Array(repeating: false, count: cols) }
        case 0x68: setANSIModes(params, true)                       // h SM
        case 0x6C: setANSIModes(params, false)                      // l RM
        case 0x6D: sgr(params)                                      // m SGR
        case 0x6E: // n DSR
            if p(0) == 5 { respond("\u{1B}[0n") }
            else if p(0) == 6 {
                let y = modes.originMode ? cursorY - scrollTop : cursorY
                respond("\u{1B}[\(y + 1);\(cursorX + 1)R")
            }
        case 0x72: // r DECSTBM
            let top = p(0, 1) - 1, bot = p(1, rows) - 1
            if top < bot && bot < rows {
                scrollTop = top; scrollBottom = bot
                cup(row: 1, col: 1)
            }
        case 0x73: saveCursor()                                     // s SCOSC
        case 0x74: // t window ops
            if p(0) == 18 { respond("\u{1B}[8;\(rows);\(cols)t") }
        case 0x75: restoreCursor()                                  // u SCORC
        default: break
        }
    }

    public func oscDispatch(_ data: [UInt8]) {
        guard let s = String(bytes: data, encoding: .utf8) else { return }
        let parts = s.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        guard let cmd = Int(parts[0]) else { return }
        let arg = parts.count > 1 ? String(parts[1]) : ""
        switch cmd {
        case 0, 2:
            title = arg
            onTitle?(arg)
        case 7: // file://host/path — shell integration reports cwd
            if let url = URL(string: arg), url.scheme == "file" {
                workingDirectory = url.path
                onWorkingDirectory?(url.path)
            }
        case 8: // hyperlinks: OSC 8 ; params ; URI
            let sub = arg.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            let uri = sub.count > 1 ? String(sub[1]) : ""
            if uri.isEmpty { pen.link = 0 } else {
                if let i = hyperlinks.lastIndex(of: uri) { pen.link = UInt16(i) }
                else if hyperlinks.count < Int(UInt16.max) { hyperlinks.append(uri); pen.link = UInt16(hyperlinks.count - 1) }
            }
        case 9: onNotification?("Mantis", arg)                       // iTerm2-style notification
        case 777: // notify;title;body
            let f = arg.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if f.first == "notify", f.count >= 3 { onNotification?(f[1], f[2]) }
        case 10, 11, 12:
            if arg == "?" {
                let c = cmd == 10 ? defaultFG : cmd == 11 ? defaultBG : cursorColor
                respond(String(format: "\u{1B}]%d;rgb:%02x%02x/%02x%02x/%02x%02x\u{1B}\\", cmd, c.r, c.r, c.g, c.g, c.b, c.b))
            }
        case 4: // palette query: 4;N;?
            let f = arg.split(separator: ";")
            if f.count == 2, f[1] == "?", let i = Int(f[0]), i >= 0, i < palette.count {
                let c = palette[i]
                respond(String(format: "\u{1B}]4;%d;rgb:%02x%02x/%02x%02x/%02x%02x\u{1B}\\", i, c.r, c.r, c.g, c.g, c.b, c.b))
            }
        case 52: // clipboard write: 52;c;base64
            let f = arg.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            if f.count == 2, f[1] != "?", let d = Data(base64Encoded: String(f[1])), let text = String(data: d, encoding: .utf8) {
                onClipboardWrite?(text)
            }
        default: break
        }
    }

    // MARK: - Operations

    private func respond(_ s: String) { onResponse?(Array(s.utf8)) }

    func blankCell() -> Cell { Cell(bg: pen.bg) }

    private func clearWide(row: Int, col: Int) {
        guard col < cols else { return }
        let c = lines[row].cells[col]
        if c.width == 0 && col > 0 { lines[row].cells[col - 1] = blankCell() }
        if c.width == 2 && col + 1 < cols { lines[row].cells[col + 1] = blankCell() }
    }

    private func pushScrollback(_ r: Row) {
        if scrollback.append(r) { droppedLines += 1 }
    }

    func setCursor(x: Int, y: Int) {
        cursorX = max(0, min(cols - 1, x))
        cursorY = max(0, min(rows - 1, y))
        pendingWrap = false
    }

    private func cup(row: Int, col: Int, ignoreOrigin: Bool = false) {
        if modes.originMode && !ignoreOrigin {
            cursorY = max(scrollTop, min(scrollBottom, scrollTop + row - 1))
            cursorX = max(0, min(cols - 1, col - 1))
            pendingWrap = false
        } else {
            setCursor(x: col - 1, y: row - 1)
        }
    }

    /// LF / IND: move down, scrolling the region if at its bottom.
    public func index() {
        if cursorY == scrollBottom { scrollUp(1) }
        else if cursorY < rows - 1 { cursorY += 1 }
    }

    func reverseIndex() {
        if cursorY == scrollTop { scrollDown(1) }
        else if cursorY > 0 { cursorY -= 1 }
    }

    func scrollUp(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        let toHistory = scrollTop == 0 && !modes.altScreen
        for _ in 0..<n {
            let r = lines.remove(at: scrollTop)
            if toHistory { pushScrollback(r) }
            lines.insert(Row(cols: cols, bg: pen.bg), at: scrollBottom)
        }
    }

    func scrollDown(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        for _ in 0..<n {
            lines.remove(at: scrollBottom)
            lines.insert(Row(cols: cols, bg: pen.bg), at: scrollTop)
        }
    }

    private func insertLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1)
        for _ in 0..<n {
            lines.remove(at: scrollBottom)
            lines.insert(Row(cols: cols, bg: pen.bg), at: cursorY)
        }
        cursorX = 0; pendingWrap = false
    }

    private func deleteLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1)
        for _ in 0..<n {
            lines.remove(at: cursorY)
            lines.insert(Row(cols: cols, bg: pen.bg), at: scrollBottom)
        }
        cursorX = 0; pendingWrap = false
    }

    private func insertChars(_ n: Int) {
        let n = min(n, cols - cursorX)
        clearWide(row: cursorY, col: cursorX)
        lines[cursorY].cells.insert(contentsOf: repeatElement(blankCell(), count: n), at: cursorX)
        lines[cursorY].cells.removeLast(n)
        if let last = lines[cursorY].cells.last, last.width == 2 { lines[cursorY].cells[cols - 1] = blankCell() }
        pendingWrap = false
    }

    private func deleteChars(_ n: Int) {
        let n = min(n, cols - cursorX)
        clearWide(row: cursorY, col: cursorX)
        lines[cursorY].cells.removeSubrange(cursorX..<(cursorX + n))
        lines[cursorY].cells.append(contentsOf: repeatElement(blankCell(), count: n))
        if lines[cursorY].cells[cursorX].width == 0 { lines[cursorY].cells[cursorX] = blankCell() }
        pendingWrap = false
    }

    private func eraseChars(_ n: Int) {
        let end = min(cols, cursorX + n)
        clearWide(row: cursorY, col: cursorX)
        if end - 1 >= cursorX { clearWide(row: cursorY, col: end - 1) }
        for x in cursorX..<end { lines[cursorY].cells[x] = blankCell() }
        pendingWrap = false
    }

    public func eraseLine(_ mode: Int) {
        let range: Range<Int>
        switch mode {
        case 0: range = cursorX..<cols
        case 1: range = 0..<min(cols, cursorX + 1)
        case 2: range = 0..<cols
        default: return
        }
        if range.lowerBound > 0 { clearWide(row: cursorY, col: range.lowerBound) }
        if range.upperBound < cols { clearWide(row: cursorY, col: range.upperBound - 1) }
        for x in range { lines[cursorY].cells[x] = blankCell() }
        if mode != 1 { lines[cursorY].wrapped = false }
        pendingWrap = false
    }

    public func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            for y in (cursorY + 1)..<max(cursorY + 1, rows) { lines[y] = Row(cols: cols, bg: pen.bg) }
        case 1:
            eraseLine(1)
            for y in 0..<cursorY { lines[y] = Row(cols: cols, bg: pen.bg) }
        case 2:
            for y in 0..<rows { lines[y] = Row(cols: cols, bg: pen.bg) }
        case 3:
            scrollback.removeAll()
            scrollOffset = 0
        default: break
        }
        pendingWrap = false
    }

    /// Clear screen + scrollback, keeping the cursor's line at the top (Cmd+K).
    public func clearScreenAndHistory() {
        let keep = lines[cursorY]
        scrollback.removeAll()
        scrollOffset = 0
        lines = Array(repeating: Row(cols: cols), count: rows)
        lines[0] = keep
        cursorY = 0
        generation &+= 1
    }

    private func tab(_ n: Int) {
        for _ in 0..<n {
            var x = cursorX + 1
            while x < cols - 1 && !tabstops[x] { x += 1 }
            cursorX = min(x, cols - 1)
        }
        pendingWrap = false
    }

    private func backTab(_ n: Int) {
        for _ in 0..<n {
            var x = cursorX - 1
            while x > 0 && !tabstops[x] { x -= 1 }
            cursorX = max(0, x)
        }
        pendingWrap = false
    }

    private func saveCursor() {
        saved = SavedCursor(x: cursorX, y: cursorY, pen: pen, originMode: modes.originMode,
                            pendingWrap: pendingWrap, charsets: charsets, gl: gl)
    }

    private func restoreCursor() {
        cursorX = min(saved.x, cols - 1); cursorY = min(saved.y, rows - 1)
        pen = saved.pen; modes.originMode = saved.originMode
        pendingWrap = saved.pendingWrap; charsets = saved.charsets; gl = saved.gl
    }

    private func enterAltScreen(saveCursor save: Bool, clear: Bool) {
        guard !modes.altScreen else { return }
        if save { savedAlt = SavedCursor(x: cursorX, y: cursorY, pen: pen, originMode: modes.originMode, pendingWrap: pendingWrap, charsets: charsets, gl: gl) }
        primaryLines = lines
        lines = Array(repeating: Row(cols: cols), count: rows)
        modes.altScreen = true
        scrollOffset = 0
        _ = clear
    }

    private func exitAltScreen(restoreCursor restore: Bool) {
        guard modes.altScreen, let p = primaryLines else { return }
        lines = p
        primaryLines = nil
        modes.altScreen = false
        if restore {
            cursorX = min(savedAlt.x, cols - 1); cursorY = min(savedAlt.y, rows - 1)
            pen = savedAlt.pen; modes.originMode = savedAlt.originMode
            pendingWrap = savedAlt.pendingWrap; charsets = savedAlt.charsets; gl = savedAlt.gl
        }
    }

    private func privateModeValue(_ m: Int) -> Bool? {
        switch m {
        case 1: return modes.appCursorKeys
        case 5: return modes.reverseVideo
        case 6: return modes.originMode
        case 7: return modes.autowrap
        case 12: return cursorBlink
        case 25: return modes.cursorVisible
        case 1000: return modes.mouseTracking == .normal
        case 1002: return modes.mouseTracking == .button
        case 1003: return modes.mouseTracking == .any
        case 1004: return modes.focusEvents
        case 1006: return modes.mouseSGR
        case 1007: return modes.alternateScroll
        case 47, 1047, 1049: return modes.altScreen
        case 2004: return modes.bracketedPaste
        case 2026: return modes.synchronizedOutput
        default: return nil
        }
    }

    private func setPrivateModes(_ params: [[Int]], _ on: Bool) {
        for g in params {
            switch g[0] {
            case 1: modes.appCursorKeys = on
            case 5: modes.reverseVideo = on
            case 6: modes.originMode = on; cup(row: 1, col: 1)
            case 7: modes.autowrap = on
            case 12: cursorBlink = on
            case 25: modes.cursorVisible = on
            case 9: modes.mouseTracking = on ? .x10 : .none
            case 1000: modes.mouseTracking = on ? .normal : .none
            case 1002: modes.mouseTracking = on ? .button : .none
            case 1003: modes.mouseTracking = on ? .any : .none
            case 1004: modes.focusEvents = on
            case 1006: modes.mouseSGR = on
            case 1007: modes.alternateScroll = on
            case 47, 1047:
                if on { enterAltScreen(saveCursor: false, clear: false) } else { exitAltScreen(restoreCursor: false) }
            case 1049:
                if on { enterAltScreen(saveCursor: true, clear: true) } else { exitAltScreen(restoreCursor: true) }
            case 2004: modes.bracketedPaste = on
            case 2026: modes.synchronizedOutput = on
            default: break
            }
        }
    }

    private func setANSIModes(_ params: [[Int]], _ on: Bool) {
        for g in params where g[0] == 4 { modes.insertMode = on }
    }

    private func sgr(_ g: [[Int]]) {
        if g.isEmpty { pen = Pen(link: pen.link); return }
        var i = 0
        while i < g.count {
            let grp = g[i]
            let v = grp[0]
            switch v {
            case 0: pen = Pen(link: pen.link)
            case 1: pen.attrs.insert(.bold)
            case 2: pen.attrs.insert(.dim)
            case 3: pen.attrs.insert(.italic)
            case 4:
                pen.attrs.subtract([.underline, .doubleUnderline, .curlyUnderline])
                let style = grp.count > 1 ? grp[1] : 1
                switch style {
                case 0: break
                case 2: pen.attrs.insert(.doubleUnderline)
                case 3: pen.attrs.insert(.curlyUnderline)
                default: pen.attrs.insert(.underline)
                }
            case 5, 6: pen.attrs.insert(.blink)
            case 7: pen.attrs.insert(.inverse)
            case 8: pen.attrs.insert(.hidden)
            case 9: pen.attrs.insert(.strike)
            case 21: pen.attrs.insert(.doubleUnderline)
            case 22: pen.attrs.subtract([.bold, .dim])
            case 23: pen.attrs.remove(.italic)
            case 24: pen.attrs.subtract([.underline, .doubleUnderline, .curlyUnderline])
            case 25: pen.attrs.remove(.blink)
            case 27: pen.attrs.remove(.inverse)
            case 28: pen.attrs.remove(.hidden)
            case 29: pen.attrs.remove(.strike)
            case 30...37: pen.fg = .indexed(UInt8(v - 30))
            case 38: if let c = extendedColor(g, &i) { pen.fg = c }
            case 39: pen.fg = .default
            case 40...47: pen.bg = .indexed(UInt8(v - 40))
            case 48: if let c = extendedColor(g, &i) { pen.bg = c }
            case 49: pen.bg = .default
            case 53: pen.attrs.insert(.overline)
            case 55: pen.attrs.remove(.overline)
            case 58: _ = extendedColor(g, &i) // underline color: parsed, not rendered yet
            case 90...97: pen.fg = .indexed(UInt8(v - 90 + 8))
            case 100...107: pen.bg = .indexed(UInt8(v - 100 + 8))
            default: break
            }
            i += 1
        }
    }

    private func extendedColor(_ g: [[Int]], _ i: inout Int) -> TermColor? {
        let grp = g[i]
        func c8(_ x: Int) -> UInt8 { UInt8(max(0, min(255, x))) }
        if grp.count > 1 { // colon form: 38:5:N or 38:2:[cs]:R:G:B
            if grp[1] == 5, grp.count >= 3 { return .indexed(c8(grp[2])) }
            if grp[1] == 2 {
                if grp.count >= 6 { return .rgb(RGB(c8(grp[3]), c8(grp[4]), c8(grp[5]))) }
                if grp.count == 5 { return .rgb(RGB(c8(grp[2]), c8(grp[3]), c8(grp[4]))) }
            }
            return nil
        }
        guard i + 1 < g.count else { return nil }
        if g[i + 1][0] == 5, i + 2 < g.count {
            let c = TermColor.indexed(c8(g[i + 2][0])); i += 2; return c
        }
        if g[i + 1][0] == 2, i + 4 < g.count {
            let c = TermColor.rgb(RGB(c8(g[i + 2][0]), c8(g[i + 3][0]), c8(g[i + 4][0]))); i += 4; return c
        }
        return nil
    }

    private func softReset() {
        pen = Pen()
        modes.insertMode = false; modes.originMode = false; modes.autowrap = true
        modes.cursorVisible = true; modes.appCursorKeys = false; modes.appKeypad = false
        scrollTop = 0; scrollBottom = rows - 1
        charsets = [.ascii, .ascii]; gl = 0
        saved = SavedCursor()
        pendingWrap = false
    }

    public func fullReset() {
        if modes.altScreen { exitAltScreen(restoreCursor: false) }
        softReset()
        modes = Modes()
        lines = Array(repeating: Row(cols: cols), count: rows)
        scrollback.removeAll()
        scrollOffset = 0
        tabstops = Terminal.defaultTabs(cols)
        cursorX = 0; cursorY = 0
        cursorShape = .block; cursorBlink = true
        title = ""
        generation &+= 1
    }

    // MARK: - Colors

    public func resolve(_ c: TermColor, isForeground: Bool) -> RGB {
        switch c {
        case .default: return isForeground ? defaultFG : defaultBG
        case .indexed(let i): return palette[Int(i)]
        case .rgb(let rgb): return rgb
        }
    }

    // DEC Special Graphics (ESC ( 0) — line drawing used by ncurses/tmux borders.
    static let decSpecialMap: [UInt32: Unicode.Scalar] = [
        0x60: "◆", 0x61: "▒", 0x62: "␉", 0x63: "␌", 0x64: "␍", 0x65: "␊", 0x66: "°", 0x67: "±",
        0x68: "␤", 0x69: "␋", 0x6A: "┘", 0x6B: "┐", 0x6C: "┌", 0x6D: "└", 0x6E: "┼", 0x6F: "⎺",
        0x70: "⎻", 0x71: "─", 0x72: "⎼", 0x73: "⎽", 0x74: "├", 0x75: "┤", 0x76: "┴", 0x77: "┬",
        0x78: "│", 0x79: "≤", 0x7A: "≥", 0x7B: "π", 0x7C: "≠", 0x7D: "£", 0x7E: "·",
    ]
}
