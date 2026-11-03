import Foundation

/// Core value types for terminal state. (Ghostty equivalents: terminal/page.zig
/// cells, terminal/style.zig, terminal/color.zig.)

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

public struct Cell: Equatable {
    public var ch: Character
    public var fg: TermColor
    public var bg: TermColor
    public var attrs: CellAttrs
    /// 1 = normal, 2 = head of a wide char, 0 = spacer tail of a wide char.
    public var width: UInt8
    /// Index into Terminal.hyperlinks (OSC 8), 0 = none.
    public var link: UInt16

    public init(ch: Character = " ", fg: TermColor = .default, bg: TermColor = .default,
                attrs: CellAttrs = [], width: UInt8 = 1, link: UInt16 = 0) {
        self.ch = ch; self.fg = fg; self.bg = bg; self.attrs = attrs; self.width = width; self.link = link
    }

    public static let blank = Cell()
}

public struct Row: Equatable {
    public var cells: [Cell]
    /// True if this row soft-wrapped into the next (used for copy & reflow).
    public var wrapped: Bool = false
    public init(cells: [Cell], wrapped: Bool = false) { self.cells = cells; self.wrapped = wrapped }
    public init(cols: Int, bg: TermColor = .default) {
        cells = Array(repeating: Cell(bg: bg), count: cols)
    }

    public var text: String {
        var s = ""
        for c in cells where c.width != 0 { s.append(c.ch) }
        return s
    }
}

/// Fixed-capacity ring buffer used for scrollback (O(1) append/evict —
/// Ghostty uses a linked list of memory pages in PageList.zig for the same reason).
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
    public static func of(_ s: Unicode.Scalar) -> Int {
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
