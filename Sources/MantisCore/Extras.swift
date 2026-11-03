import Foundation

// Pure, testable logic behind Mantis's "quick win" features:
// hint mode, clickable file paths, highlight rules, copy-as-HTML.

public extension Row {
    /// Row text plus a map from each UTF-16 offset to its cell column, so regex
    /// matches (NSRange, UTF-16 based) can be mapped back onto the grid exactly,
    /// even with wide CJK cells and combining marks.
    func indexedText() -> (text: String, colForUTF16: [Int]) {
        var text = ""
        var map: [Int] = []
        for (x, c) in cells.enumerated() where c.width != 0 {
            let s = String(c.ch)
            text += s
            map.append(contentsOf: repeatElement(x, count: s.utf16.count))
        }
        map.append(cells.count) // sentinel for end-of-range lookups
        return (text, map)
    }
}

/// A detected span of interesting text. It may span several viewport rows
/// when the line soft-wrapped (long URLs usually do).
public struct TextMatch: Equatable {
    public enum Kind: Int, Comparable {
        case url = 0, ip, path, hash
        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }
    public struct Segment: Equatable {
        public var row: Int
        public var cols: Range<Int>
    }
    public var kind: Kind
    public var segments: [Segment]
    public var text: String

    /// First row/columns (where a hint label is drawn).
    public var row: Int { segments[0].row }
    public var cols: Range<Int> { segments[0].cols }

    public func contains(row r: Int, col c: Int) -> Bool {
        segments.contains { $0.row == r && $0.cols.contains(c) }
    }
}

public enum Detector {
    static let patterns: [(TextMatch.Kind, NSRegularExpression)] = [
        (.url, try! NSRegularExpression(pattern: #"(?:https?|ftp|file)://[^\s<>"'`]+"#)),
        (.ip, try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b"#)),
        // paths containing a slash (optionally ~ or ./ prefixed) with optional :line[:col]
        (.path, try! NSRegularExpression(pattern: #"(?:~|\.{1,2})?/?(?:[\w.\-@+]+/)+[\w.\-@+]+(?::\d+(?::\d+)?)?"#)),
        // bare file names only when followed by :line (compiler/grep output)
        (.path, try! NSRegularExpression(pattern: #"\b[\w\-+]+\.[A-Za-z][A-Za-z0-9]{0,7}:\d+(?::\d+)?"#)),
        (.hash, try! NSRegularExpression(pattern: #"\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b"#)),
    ]

    /// Finds URLs, IPs, paths and hashes on logical lines (soft-wrapped rows are
    /// joined). Overlaps resolve by priority (url > ip > path > hash).
    public static func find(in rows: [Row]) -> [TextMatch] {
        var out: [TextMatch] = []
        var r = 0
        while r < rows.count {
            // Gather one logical line.
            var text = ""
            var where16: [(row: Int, col: Int, width: Int)] = []
            var cur = r
            while true {
                for (x, c) in rows[cur].cells.enumerated() where c.width != 0 {
                    let s = String(c.ch)
                    text += s
                    where16.append(contentsOf: repeatElement((row: cur, col: x, width: Int(max(1, c.width))), count: s.utf16.count))
                }
                if rows[cur].wrapped && cur + 1 < rows.count { cur += 1 } else { break }
            }
            let ns = text as NSString
            var taken: [NSRange] = []
            var found: [(Int, TextMatch)] = []
            for (kind, re) in patterns {
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    var range = m.range
                    var s = ns.substring(with: range)
                    if kind == .url { // trim trailing punctuation that is almost never part of a URL
                        while let last = s.last, ".,;:!?'\")]}>".contains(last) {
                            if last == ")" && s.filter({ $0 == "(" }).count >= s.filter({ $0 == ")" }).count { break }
                            s.removeLast(); range.length -= String(last).utf16.count
                        }
                    }
                    if kind == .path && s.allSatisfy({ $0 == "/" || $0 == "." || $0 == "~" }) { continue }
                    guard range.length > 1 else { continue }
                    if taken.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
                    taken.append(range)
                    // Split the UTF-16 range into per-row column segments.
                    var segs: [TextMatch.Segment] = []
                    for i in range.location..<(range.location + range.length) {
                        let w = where16[i]
                        if let last = segs.last, last.row == w.row {
                            segs[segs.count - 1].cols = last.cols.lowerBound..<max(last.cols.upperBound, w.col + w.width)
                        } else {
                            segs.append(.init(row: w.row, cols: w.col..<(w.col + w.width)))
                        }
                    }
                    found.append((range.location, TextMatch(kind: kind, segments: segs, text: s)))
                }
            }
            out += found.sorted { $0.0 < $1.0 }.map(\.1)
            r = cur + 1
        }
        return out
    }
}

public enum HintLabels {
    /// Home-row-first alphabet (like Vimium/kitty hints).
    public static let alphabet = Array("asdfjklghqwertyuiopzxcvbnm")

    /// Prefix-free labels: single letters while they suffice, otherwise all two-letter.
    public static func generate(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        if count <= alphabet.count { return alphabet.prefix(count).map { String($0) } }
        var out: [String] = []
        outer: for a in alphabet { for b in alphabet {
            out.append(String([a, b]))
            if out.count == count { break outer }
        } }
        return out
    }
}

public struct FileLocation: Equatable {
    public var path: String
    public var line: Int?
    public var column: Int?

    /// Parses "src/a.swift:42:7" → (src/a.swift, 42, 7).
    public static func parse(_ s: String) -> FileLocation {
        var parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var nums: [Int] = []
        while parts.count > 1, let n = Int(parts.last!), nums.count < 2 {
            nums.insert(n, at: 0); parts.removeLast()
        }
        return FileLocation(path: parts.joined(separator: ":"), line: nums.first, column: nums.count > 1 ? nums[1] : nil)
    }

    /// Absolute path, resolving ~ and paths relative to `cwd`.
    public func resolved(cwd: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        let base = cwd ?? NSHomeDirectory()
        return ((base as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }

    /// Fills an editor command template: {file} {line} {col}.
    public func command(template: String, absolutePath: String) -> String {
        let quoted = "'" + absolutePath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return template
            .replacingOccurrences(of: "{file}", with: quoted)
            .replacingOccurrences(of: "{line}", with: String(line ?? 1))
            .replacingOccurrences(of: "{col}", with: String(column ?? 1))
    }
}

/// `highlight = REGEX=#rrggbb` — recolors matching text in all output.
public struct HighlightRule {
    public let regex: NSRegularExpression
    public let color: RGB

    public init?(spec: String) {
        guard let eq = spec.lastIndex(of: "="), let c = RGB(hex: String(spec[spec.index(after: eq)...])),
              let re = try? NSRegularExpression(pattern: String(spec[..<eq])) else { return nil }
        regex = re; color = c
    }

    /// Per-column color overrides for one row (nil = no override).
    public static func apply(_ rules: [HighlightRule], to row: Row) -> [RGB?] {
        var out = [RGB?](repeating: nil, count: row.cells.count)
        guard !rules.isEmpty else { return out }
        let (text, map) = row.indexedText()
        let len = (text as NSString).length
        for rule in rules {
            for m in rule.regex.matches(in: text, range: NSRange(location: 0, length: len)) where m.range.length > 0 {
                for x in map[m.range.location]..<map[m.range.location + m.range.length] { out[x] = rule.color }
            }
        }
        return out
    }
}

public extension Terminal {
    /// Selection as HTML with inline colors/styles (for pasting into docs, Slack, email).
    func html(in sel: Selection, fontFamily: String = "SF Mono, Menlo, monospace") -> String {
        func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", c.r, c.g, c.b) }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = ""
        let s = sel.start, e = sel.end
        for stable in s.line...e.line {
            let idx = stable - droppedLines
            guard idx >= 0 && idx < totalLines else { continue }
            let row = line(at: idx)
            let c0 = sel.rectangular ? min(sel.anchor.col, sel.head.col) : (stable == s.line ? s.col : 0)
            var c1 = sel.rectangular ? max(sel.anchor.col, sel.head.col) : (stable == e.line ? e.col : row.cells.count - 1)
            c1 = min(c1, row.cells.count - 1)
            while c1 >= c0, row.cells[c1].ch == " ", row.cells[c1].bg == .default { c1 -= 1 } // trim trailing blanks
            var lastStyle = ""
            var open = false
            if c0 <= c1 {
                for x in c0...c1 where row.cells[x].width != 0 {
                    let c = row.cells[x]
                    var fg = resolve(c.fg, isForeground: true), bg = resolve(c.bg, isForeground: false)
                    var hasBG = c.bg != .default
                    if c.attrs.contains(.inverse) { swap(&fg, &bg); hasBG = true }
                    var style = "color:\(hex(fg))"
                    if hasBG { style += ";background:\(hex(bg))" }
                    if c.attrs.contains(.bold) { style += ";font-weight:bold" }
                    if c.attrs.contains(.italic) { style += ";font-style:italic" }
                    var deco: [String] = []
                    if !c.attrs.isDisjoint(with: [.underline, .doubleUnderline, .curlyUnderline]) { deco.append("underline") }
                    if c.attrs.contains(.strike) { deco.append("line-through") }
                    if !deco.isEmpty { style += ";text-decoration:\(deco.joined(separator: " "))" }
                    if style != lastStyle {
                        if open { body += "</span>" }
                        body += "<span style=\"\(style)\">"
                        open = true; lastStyle = style
                    }
                    body += esc(String(c.ch))
                }
            }
            if open { body += "</span>" }
            if stable != e.line && !(row.wrapped && !sel.rectangular) { body += "\n" }
        }
        return "<pre style=\"font-family:\(fontFamily);background:\(hex(defaultBG));color:\(hex(defaultFG));padding:8px;\">\(body)</pre>"
    }
}
