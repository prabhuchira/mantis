/// Keyboard & mouse encoding.
/// Pure functions — no AppKit — so they are unit-testable.

public struct KeyMods: OptionSet {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let shift = KeyMods(rawValue: 1)
    public static let alt = KeyMods(rawValue: 2)
    public static let ctrl = KeyMods(rawValue: 4)
    public static let cmd = KeyMods(rawValue: 8)

    /// xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl
    var xtermParam: Int { 1 + (contains(.shift) ? 1 : 0) + (contains(.alt) ? 2 : 0) + (contains(.ctrl) ? 4 : 0) }
}

public enum SpecialKey: Equatable {
    case up, down, left, right, home, end, pageUp, pageDown, insert, forwardDelete
    case backspace, tab, enter, escape
    case f(Int)
}

public enum KeyEncoder {
    public static func encode(_ key: SpecialKey, mods: KeyMods, appCursor: Bool) -> [UInt8] {
        let esc: [UInt8] = [0x1B]
        let m = mods.xtermParam
        func csi(_ s: String) -> [UInt8] { esc + Array("[\(s)".utf8) }
        func cursorKey(_ c: Character) -> [UInt8] {
            if m > 1 { return csi("1;\(m)\(c)") }
            return esc + Array((appCursor ? "O" : "[").utf8) + Array(String(c).utf8)
        }
        func tilde(_ n: Int) -> [UInt8] { m > 1 ? csi("\(n);\(m)~") : csi("\(n)~") }

        switch key {
        case .up: return cursorKey("A")
        case .down: return cursorKey("B")
        case .right: return cursorKey("C")
        case .left: return cursorKey("D")
        case .home: return cursorKey("H")
        case .end: return cursorKey("F")
        case .insert: return tilde(2)
        case .forwardDelete: return tilde(3)
        case .pageUp: return tilde(5)
        case .pageDown: return tilde(6)
        case .backspace:
            if mods.contains(.ctrl) { return [0x08] }
            return mods.contains(.alt) ? esc + [0x7F] : [0x7F]
        case .tab: return mods.contains(.shift) ? csi("Z") : [0x09]
        case .enter: return mods.contains(.alt) ? esc + [0x0D] : [0x0D]
        case .escape: return esc
        case .f(let n):
            switch n {
            case 1...4:
                let c = ["P", "Q", "R", "S"][n - 1]
                return m > 1 ? csi("1;\(m)\(c)") : esc + Array("O\(c)".utf8)
            case 5: return tilde(15)
            case 6...10: return tilde(n + 11)   // 17..21
            case 11, 12: return tilde(n + 12)   // 23, 24
            default: return []
            }
        }
    }

    /// Ctrl+<key> → C0 control byte.
    public static func control(_ ch: Character) -> UInt8? {
        guard let a = ch.asciiValue else { return nil }
        switch a {
        case 0x61...0x7A: return a - 0x60          // a-z
        case 0x41...0x5A: return a - 0x40          // A-Z
        case 0x40, 0x20, 0x32: return 0            // @, space, 2
        case 0x5B, 0x33: return 0x1B               // [, 3
        case 0x5C, 0x34: return 0x1C               // \, 4
        case 0x5D, 0x35: return 0x1D               // ], 5
        case 0x5E, 0x36: return 0x1E               // ^, 6
        case 0x5F, 0x2D, 0x37: return 0x1F         // _, -, 7
        case 0x3F, 0x2F, 0x38: return 0x7F         // ?, /, 8
        default: return nil
        }
    }

    /// Prepare pasted text for the pty (bracketed paste strips embedded end markers).
    public static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        if bracketed {
            let clean = text.replacingOccurrences(of: "\u{1B}[201~", with: "")
            return Array("\u{1B}[200~\(clean)\u{1B}[201~".utf8)
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        return Array(normalized.utf8)
    }

    /// Paste-protection heuristic: multi-line pastes
    /// without bracketed paste can execute commands immediately.
    public static func isUnsafePaste(_ text: String, bracketed: Bool) -> Bool {
        if text.contains("\u{1B}[201~") { return true }
        return !bracketed && (text.contains("\n") || text.contains("\r"))
    }
}

public enum MouseButton: Int { case left = 0, middle = 1, right = 2, none = 3, wheelUp = 64, wheelDown = 65 }

public enum MouseEncoder {
    /// Encode a mouse event (x, y are 0-based cell coordinates).
    public static func encode(button: MouseButton, x: Int, y: Int, pressed: Bool, motion: Bool,
                              mods: KeyMods, sgr: Bool) -> [UInt8] {
        var code = button.rawValue
        if motion { code += 32 }
        if mods.contains(.shift) { code += 4 }
        if mods.contains(.alt) { code += 8 }
        if mods.contains(.ctrl) { code += 16 }
        if sgr {
            return Array("\u{1B}[<\(code);\(x + 1);\(y + 1)\(pressed ? "M" : "m")".utf8)
        }
        // Legacy X10/normal encoding: release is reported as button 3.
        if !pressed && button.rawValue < 64 { code = (code & ~3) | 3 }
        func enc(_ v: Int) -> UInt8 { UInt8(min(255, 32 + v)) }
        return [0x1B, 0x5B, 0x4D, enc(code), enc(x + 1), enc(y + 1)]
    }
}

// MARK: - Selection

public struct GridPoint: Equatable, Comparable {
    /// Stable line number: `terminal.droppedLines + absolute index`.
    public var line: Int
    public var col: Int
    public init(line: Int, col: Int) { self.line = line; self.col = col }
    public static func < (a: GridPoint, b: GridPoint) -> Bool { a.line != b.line ? a.line < b.line : a.col < b.col }
}

public struct Selection: Equatable {
    public var anchor: GridPoint
    public var head: GridPoint
    public var rectangular = false
    public init(anchor: GridPoint, head: GridPoint) { self.anchor = anchor; self.head = head }
    public var start: GridPoint { min(anchor, head) }
    public var end: GridPoint { max(anchor, head) }

    public func contains(line: Int, col: Int) -> Bool {
        if rectangular {
            let c0 = min(anchor.col, head.col), c1 = max(anchor.col, head.col)
            return line >= start.line && line <= end.line && col >= c0 && col <= c1
        }
        let p = GridPoint(line: line, col: col)
        return p >= start && p <= end
    }
}

public extension Terminal {
    func stablePoint(viewportRow r: Int, col: Int) -> GridPoint {
        GridPoint(line: droppedLines + absIndex(viewportRow: r), col: col)
    }

    /// Selected text; soft-wrapped rows are joined, trailing blanks trimmed.
    func text(in sel: Selection) -> String {
        var out = ""
        let s = sel.start, e = sel.end
        for stable in s.line...e.line {
            let idx = stable - droppedLines
            guard idx >= 0 && idx < totalLines else { continue }
            let row = line(at: idx)
            let c0 = sel.rectangular ? min(sel.anchor.col, sel.head.col) : (stable == s.line ? s.col : 0)
            let c1 = sel.rectangular ? max(sel.anchor.col, sel.head.col) : (stable == e.line ? e.col : row.cells.count - 1)
            var piece = ""
            if c0 <= c1 {
                for x in c0...min(c1, row.cells.count - 1) where row.cells[x].width != 0 {
                    piece.append(row.cells[x].ch)
                }
            }
            let joinNext = row.wrapped && stable != e.line && !sel.rectangular
            if !joinNext { while piece.last == " " { piece.removeLast() } }
            out += piece
            if stable != e.line && !joinNext { out += "\n" }
        }
        return out
    }

    /// Word boundaries around a point (double-click selection).
    func wordSelection(at p: GridPoint) -> Selection {
        let idx = p.line - droppedLines
        guard idx >= 0 && idx < totalLines else { return Selection(anchor: p, head: p) }
        let cells = line(at: idx).cells
        func isWord(_ c: Cell) -> Bool {
            if c.width == 0 { return true }
            let ch = c.ch
            return !(ch == " " || "\t\"'`()[]{}<>|│,;".contains(ch))
        }
        guard p.col < cells.count, isWord(cells[p.col]) else { return Selection(anchor: p, head: p) }
        var a = p.col, b = p.col
        while a > 0 && isWord(cells[a - 1]) { a -= 1 }
        while b < cells.count - 1 && isWord(cells[b + 1]) { b += 1 }
        return Selection(anchor: GridPoint(line: p.line, col: a), head: GridPoint(line: p.line, col: b))
    }

    func lineSelection(at p: GridPoint) -> Selection {
        Selection(anchor: GridPoint(line: p.line, col: 0), head: GridPoint(line: p.line, col: cols - 1))
    }

    /// Case-insensitive search across scrollback + screen. Returns matches as selections.
    func search(_ needle: String, limit: Int = 1000) -> [Selection] {
        guard !needle.isEmpty else { return [] }
        let n = Array(needle.lowercased())
        var out: [Selection] = []
        for idx in 0..<totalLines {
            let cells = line(at: idx).cells
            let chars = cells.map { $0.width == 0 ? "\u{0}" : ($0.ch.lowercased().first ?? $0.ch) }
            guard chars.count >= n.count else { continue }
            var x = 0
            while x <= chars.count - n.count {
                if chars[x] == n[0] && Array(chars[x..<(x + n.count)]) == n {
                    let st = droppedLines + idx
                    out.append(Selection(anchor: GridPoint(line: st, col: x), head: GridPoint(line: st, col: x + n.count - 1)))
                    if out.count >= limit { return out }
                    x += n.count
                } else { x += 1 }
            }
        }
        return out
    }
}
