import XCTest
@testable import MantisCore

final class ExtrasTests: XCTestCase {
    func rows(_ s: String, cols: Int = 80) -> [Row] {
        let t = Terminal(cols: cols, rows: 4)
        t.feed(s)
        return (0..<t.rows).map { t.lines[$0] }
    }

    func testDetectorKinds() {
        let m = Detector.find(in: rows("see https://example.com/docs). at 10.0.0.1:8080 in src/app/main.swift:42:7 commit 3f9a2c1d"))
        XCTAssertEqual(m.map(\.kind), [.url, .ip, .path, .hash])
        XCTAssertEqual(m.map(\.text), ["https://example.com/docs", "10.0.0.1:8080", "src/app/main.swift:42:7", "3f9a2c1d"])
        XCTAssertEqual(m[0].cols, 4..<28)
    }

    func testDetectorBareFileWithLineAndNoFalsePositives() {
        let m = Detector.find(in: rows("error in Parser.swift:12 version 1.2 word deadbeefcafe ok"))
        XCTAssertEqual(m.map(\.text), ["Parser.swift:12"]) // "1.2" not a path, all-letter hex not a hash
    }

    func testDetectorColumnsWithWideChars() {
        let m = Detector.find(in: rows("漢字 https://x.dev"))
        XCTAssertEqual(m.first?.cols, 5..<18) // two wide chars occupy 4 cells + space
    }

    func testURLKeepsBalancedParens() {
        let m = Detector.find(in: rows("https://en.wikipedia.org/wiki/Foo_(bar)."))
        XCTAssertEqual(m.first?.text, "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    func testDetectorJoinsSoftWrappedLines() {
        let t = Terminal(cols: 15, rows: 4)
        t.feed("go https://example.com/a/very/long/path ok") // 3 + 36 chars → rows 0,1,2
        let m = Detector.find(in: (0..<t.rows).map { t.lines[$0] })
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].text, "https://example.com/a/very/long/path")
        XCTAssertEqual(m[0].segments.map(\.row), [0, 1, 2])
        XCTAssertEqual(m[0].segments.first?.cols, 3..<15)
        XCTAssertEqual(m[0].segments.last?.cols, 0..<9)
        XCTAssertTrue(m[0].contains(row: 1, col: 10))
        XCTAssertFalse(m[0].contains(row: 2, col: 9)) // the space before "ok"
    }

    func testHintLabelsArePrefixFree() {
        XCTAssertEqual(HintLabels.generate(3), ["a", "s", "d"])
        let many = HintLabels.generate(40)
        XCTAssertEqual(many.count, 40)
        XCTAssertTrue(many.allSatisfy { $0.count == 2 })
        XCTAssertEqual(Set(many).count, 40)
    }

    func testFileLocation() {
        XCTAssertEqual(FileLocation.parse("src/a.swift:42:7"), FileLocation(path: "src/a.swift", line: 42, column: 7))
        XCTAssertEqual(FileLocation.parse("/etc/hosts"), FileLocation(path: "/etc/hosts", line: nil, column: nil))
        let f = FileLocation.parse("a b/it's.txt:3")
        XCTAssertEqual(f.resolved(cwd: "/tmp/x"), "/tmp/x/a b/it's.txt")
        XCTAssertEqual(f.command(template: "code -g {file}:{line}:{col}", absolutePath: "/p/it's.txt"),
                       "code -g '/p/it'\\''s.txt':3:1")
    }

    func testHighlightRules() {
        let rules = [HighlightRule(spec: "ERROR|FAIL=#ff0000")!, HighlightRule(spec: "WARN=#ffff00")!]
        let row = rows("ok ERROR then WARN")[0]
        let colors = HighlightRule.apply(rules, to: row)
        XCTAssertNil(colors[0])
        XCTAssertEqual(colors[3], RGB(255, 0, 0)); XCTAssertEqual(colors[7], RGB(255, 0, 0)); XCTAssertNil(colors[8])
        XCTAssertEqual(colors[14], RGB(255, 255, 0))
        XCTAssertNil(HighlightRule(spec: "nocolor"))
        XCTAssertNil(HighlightRule(spec: "([bad=#ffffff"))
    }

    func testCopyAsHTML() {
        let t = Terminal(cols: 20, rows: 2)
        t.feed("\u{1B}[1;31mred\u{1B}[0m <b>")
        let sel = Selection(anchor: t.stablePoint(viewportRow: 0, col: 0), head: t.stablePoint(viewportRow: 0, col: 19))
        let html = t.html(in: sel)
        XCTAssertTrue(html.contains("<span style=\"color:#e0616b;font-weight:bold\">red</span>"), html)
        XCTAssertTrue(html.contains("&lt;b&gt;"))
        XCTAssertTrue(html.hasPrefix("<pre"))
    }
}
