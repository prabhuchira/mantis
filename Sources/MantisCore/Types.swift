import Foundation

/// Core value types for terminal state: cells, styles, colors.

public struct RGB: Equatable, Hashable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }

    /// Parse "#rrggbb" or "rrggbb".
    public init?(hex: String) {
        var s = Substring(hex.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("#") { s = s.dropFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    public func blended(with o: RGB, _ t: Double) -> RGB {
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8(Double(a) * (1 - t) + Double(b) * t) }
        return RGB(m(r, o.r), m(g, o.g), m(b, o.b))
    }
}

public enum TermColor: Equatable, Hashable {
    case `default`
    case indexed(UInt8)
    case rgb(RGB)
}

public struct CellAttrs: OptionSet, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let bold = CellAttrs(rawValue: 1 << 0)
    public static let dim = CellAttrs(rawValue: 1 << 1)
    public static let italic = CellAttrs(rawValue: 1 << 2)
    public static let underline = CellAttrs(rawValue: 1 << 3)
    public static let blink = CellAttrs(rawValue: 1 << 4)
    public static let inverse = CellAttrs(rawValue: 1 << 5)
    public static let hidden = CellAttrs(rawValue: 1 << 6)
    public static let strike = CellAttrs(rawValue: 1 << 7)
    public static let doubleUnderline = CellAttrs(rawValue: 1 << 8)
    public static let curlyUnderline = CellAttrs(rawValue: 1 << 9)
    public static let overline = CellAttrs(rawValue: 1 << 10)
}

/// One grid cell. Plain-old-data (no references), so copying rows is a memcpy with no
/// reference counting.
public struct Cell: Equatable {
    /// A Unicode scalar value, or — with `Cell.clusterFlag` set — an index into
    /// `Graphemes` for multi-scalar characters (combining marks, ZWJ emoji, flags).
    public var code: UInt32
    public var fg: TermColor
    public var bg: TermColor
    public var attrs: CellAttrs
    /// 1 = normal, 2 = head of a wide char, 0 = spacer tail of a wide char.
    public var width: UInt8
    /// Index into Terminal.hyperlinks (OSC 8), 0 = none.
    public var link: UInt16

    public static let clusterFlag: UInt32 = 0x8000_0000

    public init(ch: Character = " ", fg: TermColor = .default, bg: TermColor = .default,
                attrs: CellAttrs = [], width: UInt8 = 1, link: UInt16 = 0) {
        self.init(code: Graphemes.encode(ch), fg: fg, bg: bg, attrs: attrs, width: width, link: link)
    }

    public init(code: UInt32, fg: TermColor = .default, bg: TermColor = .default,
                attrs: CellAttrs = [], width: UInt8 = 1, link: UInt16 = 0) {
        self.code = code; self.fg = fg; self.bg = bg; self.attrs = attrs; self.width = width; self.link = link
    }

    /// The cell's character (decoded on demand; prefer `code`/`ascii` in hot loops).
    public var ch: Character {
        get { Graphemes.decode(code) }
        set { code = Graphemes.encode(newValue) }
    }

    /// The byte value if this cell holds a single ASCII character.
    @inline(__always) public var ascii: UInt8? { code < 0x80 ? UInt8(truncatingIfNeeded: code) : nil }
    @inline(__always) public var isSpace: Bool { code == 0x20 }

    public static let blank = Cell()
}

/// Interned multi-scalar characters. They are rare (a few per screen at most), so a
/// process-wide table keeps `Cell` at a fixed small size without per-cell allocations.
public enum Graphemes {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var list: [Character] = []
        var index: [Character: UInt32] = [:]
    }
    private static let store = Store()

    @inline(__always) public static func encode(_ c: Character) -> UInt32 {
        let scalars = c.unicodeScalars
        if scalars.count == 1 { return scalars.first!.value }
        let s = store
        s.lock.lock(); defer { s.lock.unlock() }
        if let i = s.index[c] { return i | Cell.clusterFlag }
        let i = UInt32(s.list.count)
        s.list.append(c); s.index[c] = i
        return i | Cell.clusterFlag
    }

    @inline(__always) public static func decode(_ code: UInt32) -> Character {
        if code & Cell.clusterFlag == 0 { return Character(Unicode.Scalar(code) ?? "\u{FFFD}") }
        let s = store
        s.lock.lock(); defer { s.lock.unlock() }
        let i = Int(code & ~Cell.clusterFlag)
        return i < s.list.count ? s.list[i] : "\u{FFFD}"
    }
}

public struct Row: Equatable {
    public var cells: [Cell]
    /// True if this row soft-wrapped into the next (used for copy & reflow).
    public var wrapped: Bool = false
    public init(cells: [Cell], wrapped: Bool = false) { self.cells = cells; self.wrapped = wrapped }
    public init(cols: Int, bg: TermColor = .default) {
        cells = Array(repeating: Cell(bg: bg), count: cols)
    }

    /// Reset to blank, copying from a prebuilt blank row (one memcpy, no per-cell loop)
    /// and reusing the existing buffer when the width matches.
    public mutating func reset(template: [Cell]) {
        wrapped = false
        if cells.count == template.count {
            cells.withUnsafeMutableBufferPointer { dst in
                template.withUnsafeBufferPointer { src in dst.baseAddress!.update(from: src.baseAddress!, count: src.count) }
            }
        } else {
            cells = template
        }
    }

    public mutating func reset(cols: Int, bg: TermColor = .default) {
        reset(template: Array(repeating: Cell(code: 0x20, bg: bg), count: cols))
    }

    public var text: String {
        var s = ""
        for c in cells where c.width != 0 { s.append(c.ch) }
        return s
    }
}

/// Fixed-capacity ring buffer used for scrollback (O(1) append/evict).
public struct RingBuffer<T> {
    private var storage: [T?] = []
    private var head = 0
    public private(set) var count = 0
    public let capacity: Int

    public init(capacity: Int) { self.capacity = max(0, capacity) }

    /// Appends; returns true if the oldest element was evicted (or dropped).
    @discardableResult
    public mutating func append(_ x: T) -> Bool {
        guard capacity > 0 else { return true }
        if count < capacity {
            let idx = (head + count) % capacity
            if idx < storage.count { storage[idx] = x } else { storage.append(x) }
            count += 1
            return false
        }
        storage[head] = x
        head = (head + 1) % capacity
        return true
    }

    /// Appends, handing back the evicted oldest element (if any) so its storage can be reused.
    public mutating func appendEvicting(_ x: T) -> T? {
        guard capacity > 0 else { return x }
        if count < capacity { append(x); return nil }
        let old = storage[head].take()
        storage[head] = x
        head = (head + 1) % capacity
        return old
    }

    public subscript(i: Int) -> T {
        get { storage[(head + i) % capacity]! }
        set { storage[(head + i) % capacity] = newValue }
    }

    @discardableResult
    public mutating func removeLast() -> T {
        count -= 1
        let idx = (head + count) % capacity
        let v = storage[idx]!
        storage[idx] = nil
        return v
    }

    public mutating func removeAll() {
        storage = []; head = 0; count = 0
    }
}

// MARK: - Character width (simplified wcwidth / East Asian Width)

public enum CharWidth {
    /// Widths for the whole Basic Multilingual Plane, computed once (a few ms) on first use:
    /// Unicode property lookups are far too slow to do per printed character.
    private static let bmp: [UInt8] = (0..<0x10000).map { v in
        guard let u = Unicode.Scalar(UInt32(v)) else { return 1 } // surrogates never reach us
        return UInt8(compute(u))
    }

    @inline(__always) public static func of(_ s: Unicode.Scalar) -> Int {
        let v = s.value
        if v >= 0x20 && v < 0x7F { return 1 }
        if v < 0x10000 { return Int(bmp[Int(v)]) }
        return compute(s)
    }

    static func compute(_ s: Unicode.Scalar) -> Int {
        let v = s.value
        if v < 0x20 || (v >= 0x7F && v < 0xA0) { return 0 }
        if v < 0x300 { return 1 }
        if v == 0x200B || v == 0x200C || v == 0x200D || v == 0xFE0E || v == 0xFE0F { return 0 }
        switch s.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        if (0x1F3FB...0x1F3FF).contains(v) { return 0 } // skin-tone modifiers combine
        if s.properties.isEmojiPresentation { return 2 }
        switch v {
        case 0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A,
             0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

// MARK: - Palette

public enum Palette {
    /// Mantis's default 16-color theme ("Mantis Night").
    public static let base16: [RGB] = [
        "1c1f26", "e0616b", "8ccf7e", "e5c76b", "67b0e8", "c47fd5", "6cd0ca", "c4c8d0",
        "4a5162", "ef7a83", "a3e094", "f0d68a", "85c2f0", "d59ae2", "8ce0da", "eef0f4",
    ].map { RGB(hex: $0)! }

    /// Builds the xterm 256-color palette from 16 base colors.
    public static func make256(base: [RGB] = base16) -> [RGB] {
        var p = base
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 {
            p.append(RGB(steps[r], steps[g], steps[b]))
        } } }
        for i in 0..<24 {
            let v = UInt8(8 + i * 10)
            p.append(RGB(v, v, v))
        }
        return p
    }
}
