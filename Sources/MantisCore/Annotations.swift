import Foundation

/// A PDF-style marker highlight on terminal text, kept for the life of the session.
///
/// Anchoring: the range uses *stable* line numbers (`droppedLines + absolute index`),
/// so highlights stay on their text while the screen scrolls and scrollback grows.
/// Because terminal content can be rewritten in place (`clear`, TUIs, ⌘K), each
/// highlight also remembers the exact text it covered and is only shown while that
/// text is still there — it never ends up painted over unrelated output.
public struct Annotation: Identifiable, Equatable {
    public let id: UUID
    public var range: Selection
    public var colorIndex: Int
    public var note: String?
    /// The text that was highlighted (used to verify the anchor is still valid).
    public let text: String
    /// Highlights belong to the screen they were made on (primary vs. alternate).
    public let altScreen: Bool
    public let created: Date
}

public struct AnnotationStore {
    public private(set) var items: [Annotation] = []
    public init() {}

    public var isEmpty: Bool { items.isEmpty }

    /// Highlight a selection. Returns nil for blank selections. Existing highlights
    /// fully covered by the new one are replaced (re-marking a region recolors it).
    @discardableResult
    public mutating func add(_ sel: Selection, colorIndex: Int, note: String? = nil, in t: Terminal) -> Annotation? {
        let text = t.text(in: sel)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let alt = t.modes.altScreen
        items.removeAll { $0.altScreen == alt && sel.contains(line: $0.range.start.line, col: $0.range.start.col)
                                              && sel.contains(line: $0.range.end.line, col: $0.range.end.col) }
        let a = Annotation(id: UUID(), range: sel, colorIndex: colorIndex, note: note, text: text,
                           altScreen: alt, created: Date())
        items.append(a)
        return a
    }

    public mutating func remove(id: UUID) { items.removeAll { $0.id == id } }
    public mutating func removeAll() { items.removeAll() }

    /// Remove highlights overlapping a selection (e.g. "Remove Highlight" over selected text).
    @discardableResult
    public mutating func remove(overlapping sel: Selection) -> Int {
        let before = items.count
        items.removeAll { a in
            !(a.range.end < sel.start || sel.end < a.range.start)
        }
        return before - items.count
    }

    public mutating func setColor(id: UUID, _ colorIndex: Int) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].colorIndex = colorIndex }
    }

    public mutating func setNote(id: UUID, _ note: String?) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            items[i].note = note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? note : nil
        }
    }

    /// Drop highlights whose lines were evicted from scrollback.
    public mutating func prune(_ t: Terminal) {
        items.removeAll { $0.range.start.line < t.droppedLines }
    }

    /// Highlights that should be drawn right now: same screen, and the text is unchanged.
    public func live(in t: Terminal) -> [Annotation] {
        items.filter { $0.altScreen == t.modes.altScreen && $0.range.start.line >= t.droppedLines && t.text(in: $0.range) == $0.text }
    }

    public func annotation(at p: GridPoint, in t: Terminal) -> Annotation? {
        live(in: t).last { $0.range.contains(line: p.line, col: p.col) }
    }

    /// Next/previous live highlight relative to a stable line (document order).
    public func neighbor(of line: Int, forward: Bool, in t: Terminal) -> Annotation? {
        let sorted = live(in: t).sorted { $0.range.start < $1.range.start }
        return forward ? sorted.first { $0.range.start.line > line } : sorted.last { $0.range.start.line < line }
    }

    /// Markdown list of live highlights in document order (for "Copy All Highlights").
    public func markdown(in t: Terminal, colorNames: [String]) -> String {
        live(in: t).sorted { $0.range.start < $1.range.start }.map { a in
            let name = colorNames.indices.contains(a.colorIndex) ? colorNames[a.colorIndex] : "highlight"
            let body = a.text.contains("\n") ? "\n```\n\(a.text)\n```" : " `\(a.text)`"
            return "- **\(name)**\(body)" + (a.note.map { "\n  > \($0)" } ?? "")
        }.joined(separator: "\n")
    }
}
