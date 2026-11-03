import XCTest
@testable import MantisCore

final class AnnotationTests: XCTestCase {
    func sel(_ t: Terminal, _ r0: Int, _ c0: Int, _ r1: Int, _ c1: Int) -> Selection {
        Selection(anchor: t.stablePoint(viewportRow: r0, col: c0), head: t.stablePoint(viewportRow: r1, col: c1))
    }

    func testAddCapturesTextAndIgnoresBlank() {
        let t = Terminal(cols: 20, rows: 4)
        t.feed("hello world\r\n")
        var s = AnnotationStore()
        let a = s.add(sel(t, 0, 6, 0, 10), colorIndex: 1, in: t)
        XCTAssertEqual(a?.text, "world")
        XCTAssertNil(s.add(sel(t, 2, 0, 2, 5), colorIndex: 0, in: t)) // blank row
        XCTAssertEqual(s.live(in: t).count, 1)
    }

    func testSurvivesScrollingIntoScrollback() {
        let t = Terminal(cols: 20, rows: 3)
        t.feed("keep me\r\n")
        var s = AnnotationStore()
        s.add(sel(t, 0, 0, 0, 6), colorIndex: 0, in: t)
        for i in 0..<10 { t.feed("line \(i)\r\n") } // pushes "keep me" into scrollback
        XCTAssertGreaterThan(t.scrollback.count, 0)
        XCTAssertEqual(s.live(in: t).count, 1)
        XCTAssertEqual(t.text(in: s.items[0].range), "keep me")
    }

    func testHidesWhenTextIsOverwritten() {
        let t = Terminal(cols: 20, rows: 3)
        t.feed("secret value")
        var s = AnnotationStore()
        s.add(sel(t, 0, 7, 0, 11), colorIndex: 0, in: t)
        XCTAssertEqual(s.live(in: t).count, 1)
        t.feed("\u{1B}[2J\u{1B}[Hsomething else") // `clear` then new output in the same place
        XCTAssertEqual(s.live(in: t).count, 0)    // stale: not drawn over unrelated text
        XCTAssertEqual(s.items.count, 1)          // but not silently deleted
    }

    func testAltScreenIsolation() {
        let t = Terminal(cols: 20, rows: 3)
        t.feed("prompt$ ")
        var s = AnnotationStore()
        s.add(sel(t, 0, 0, 0, 5), colorIndex: 0, in: t)
        t.feed("\u{1B}[?1049h\u{1B}[Hprompt in vim")
        XCTAssertEqual(s.live(in: t).count, 0) // primary-screen highlight not shown in vim
        t.feed("\u{1B}[?1049l")
        XCTAssertEqual(s.live(in: t).count, 1)
    }

    func testPruneAfterEviction() {
        let t = Terminal(cols: 10, rows: 1, scrollbackLimit: 2)
        t.feed("first")
        var s = AnnotationStore()
        s.add(sel(t, 0, 0, 0, 4), colorIndex: 0, in: t)
        for i in 0..<5 { t.feed("\r\n\(i)") }
        s.prune(t)
        XCTAssertTrue(s.isEmpty)
    }

    func testRecolorReplaceRemoveAndNotes() {
        let t = Terminal(cols: 30, rows: 2)
        t.feed("alpha beta gamma")
        var s = AnnotationStore()
        let a = s.add(sel(t, 0, 6, 0, 9), colorIndex: 0, in: t)!
        s.add(sel(t, 0, 0, 0, 15), colorIndex: 2, in: t) // covers "beta" → replaces it
        XCTAssertEqual(s.items.count, 1)
        XCTAssertNil(s.items.first { $0.id == a.id })
        let b = s.items[0]
        s.setColor(id: b.id, 3); s.setNote(id: b.id, "  important ")
        XCTAssertEqual(s.items[0].colorIndex, 3)
        XCTAssertEqual(s.items[0].note, "  important ")
        s.setNote(id: b.id, "   "); XCTAssertNil(s.items[0].note)
        XCTAssertEqual(s.annotation(at: t.stablePoint(viewportRow: 0, col: 8), in: t)?.id, b.id)
        XCTAssertEqual(s.remove(overlapping: sel(t, 0, 2, 0, 3)), 1)
        XCTAssertTrue(s.isEmpty)
    }

    func testNavigationAndMarkdown() {
        let t = Terminal(cols: 20, rows: 5)
        t.feed("one\r\ntwo\r\nthree\r\nfour")
        var s = AnnotationStore()
        s.add(sel(t, 2, 0, 2, 4), colorIndex: 1, in: t)
        s.add(sel(t, 0, 0, 0, 2), colorIndex: 0, note: "start here", in: t)
        let mid = t.stablePoint(viewportRow: 1, col: 0).line
        XCTAssertEqual(s.neighbor(of: mid, forward: true, in: t)?.text, "three")
        XCTAssertEqual(s.neighbor(of: mid, forward: false, in: t)?.text, "one")
        XCTAssertEqual(s.markdown(in: t, colorNames: ["Yellow", "Green"]),
                       "- **Yellow** `one`\n  > start here\n- **Green** `three`")
    }
}
