import XCTest
@testable import MantisCore

final class RecordingHandler: ParserHandler {
    var events: [String] = []
    func print(_ s: Unicode.Scalar) { events.append("print(\(s))") }
    func execute(_ b: UInt8) { events.append("exec(\(b))") }
    func csiDispatch(params: [[Int]], intermediates: [UInt8], final: UInt8) {
        events.append("csi(\(params),\(String(bytes: intermediates, encoding: .ascii)!),\(Character(Unicode.Scalar(final))))")
    }
    func escDispatch(intermediates: [UInt8], final: UInt8) { events.append("esc(\(Character(Unicode.Scalar(final))))") }
    func oscDispatch(_ d: [UInt8]) { events.append("osc(\(String(bytes: d, encoding: .utf8)!))") }
}

final class ParserTests: XCTestCase {
    func run(_ s: String) -> [String] {
        let p = Parser(); let h = RecordingHandler(); p.handler = h
        p.feed(Array(s.utf8)); return h.events
    }

    func testPrintAndExecute() {
        XCTAssertEqual(run("a\r\n"), ["print(a)", "exec(13)", "exec(10)"])
    }

    func testCSIParamsAndPrivate() {
        XCTAssertEqual(run("\u{1B}[1;31m"), ["csi([[1], [31]],,m)"])
        XCTAssertEqual(run("\u{1B}[?1049h"), ["csi([[1049]],?,h)"])
        XCTAssertEqual(run("\u{1B}[;5H"), ["csi([[0], [5]],,H)"])
    }

    func testColonSubparams() {
        XCTAssertEqual(run("\u{1B}[38:2::10:20:30m"), ["csi([[38, 2, 0, 10, 20, 30]],,m)"])
    }

    func testOSCWithBELAndST() {
        XCTAssertEqual(run("\u{1B}]0;hi\u{07}"), ["osc(0;hi)"])
        XCTAssertEqual(run("\u{1B}]2;yo\u{1B}\\"), ["osc(2;yo)", "esc(\\)"])
    }

    func testUTF8() {
        XCTAssertEqual(run("é漢🙂"), ["print(é)", "print(漢)", "print(🙂)"])
        XCTAssertEqual(run("\u{FF}"), ["print(\u{FF})"]) // valid 2-byte
        let p = Parser(); let h = RecordingHandler(); p.handler = h
        p.feed([0xE6, 0x41]) // truncated sequence then 'A'
        XCTAssertEqual(h.events, ["print(\u{FFFD})", "print(A)"])
    }

    func testCancelAborts() {
        XCTAssertEqual(run("\u{1B}[12\u{18}x"), ["exec(24)", "print(x)"])
    }
}

final class TerminalTests: XCTestCase {
    func screen(_ t: Terminal) -> [String] {
        (0..<t.rows).map { t.lines[$0].text.replacingOccurrences(of: " +$", with: "", options: .regularExpression) }
    }

    func testPrintWrapAndScroll() {
        let t = Terminal(cols: 5, rows: 3)
        t.feed("abcdefgh\r\nxy\r\nz")
        XCTAssertEqual(screen(t), ["fgh", "xy", "z"])
        XCTAssertEqual(t.scrollback.count, 1)
        XCTAssertEqual(t.scrollback[0].text, "abcde")
        XCTAssertTrue(t.scrollback[0].wrapped)
    }

    func testPendingWrap() {
        let t = Terminal(cols: 3, rows: 2)
        t.feed("abc")
        XCTAssertEqual(t.cursorX, 2); XCTAssertEqual(t.cursorY, 0)
        t.feed("\r") // CR clears pending wrap — no new line
        t.feed("X")
        XCTAssertEqual(screen(t), ["Xbc", ""])
    }

    func testCursorMovementAndErase() {
        let t = Terminal(cols: 10, rows: 3)
        t.feed("hello world")
        t.feed("\u{1B}[1;3H\u{1B}[K")
        XCTAssertEqual(screen(t)[0], "he")
        t.feed("\u{1B}[2J")
        XCTAssertEqual(screen(t), ["", "", ""])
    }

    func testSGRColors() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("\u{1B}[1;31mR\u{1B}[38;2;1;2;3mT\u{1B}[48;5;200mB\u{1B}[0mN")
        let c = t.lines[0].cells
        XCTAssertEqual(c[0].fg, .indexed(1)); XCTAssertTrue(c[0].attrs.contains(.bold))
        XCTAssertEqual(c[1].fg, .rgb(RGB(1, 2, 3)))
        XCTAssertEqual(c[2].bg, .indexed(200))
        XCTAssertEqual(c[3].fg, .default); XCTAssertEqual(c[3].attrs, [])
    }

    func testWideCharacters() {
        let t = Terminal(cols: 4, rows: 2)
        t.feed("漢a漢")
        XCTAssertEqual(t.lines[0].cells[0].width, 2)
        XCTAssertEqual(t.lines[0].cells[1].width, 0)
        XCTAssertEqual(t.lines[0].text, "漢a ")  // blank pad before wrapped wide char
        XCTAssertEqual(t.lines[1].text.trimmingCharacters(in: .whitespaces), "漢") // wide char wrapped
    }

    func testCombining() {
        let t = Terminal(cols: 4, rows: 1)
        t.feed("e\u{301}x")
        XCTAssertEqual(t.lines[0].cells[0].ch, "é")
        XCTAssertEqual(t.lines[0].cells[1].ch, "x")
    }

    func testScrollRegion() {
        let t = Terminal(cols: 5, rows: 4)
        t.feed("1\r\n2\r\n3\r\n4")
        t.feed("\u{1B}[2;3r\u{1B}[3;1H\n")
        XCTAssertEqual(screen(t), ["1", "3", "", "4"])
        XCTAssertEqual(t.scrollback.count, 0) // region scroll does not touch history
    }

    func testAltScreen() {
        let t = Terminal(cols: 5, rows: 2)
        t.feed("main")
        t.feed("\u{1B}[?1049h\u{1B}[HALT")
        XCTAssertEqual(screen(t), ["ALT", ""])
        t.feed("\u{1B}[?1049l")
        XCTAssertEqual(screen(t), ["main", ""])
        XCTAssertEqual(t.cursorX, 4)
    }

    func testDeviceStatusResponse() {
        let t = Terminal(cols: 10, rows: 5)
        var out = ""
        t.onResponse = { out += String(bytes: $0, encoding: .utf8)! }
        t.feed("\u{1B}[3;4H\u{1B}[6n\u{1B}[c")
        XCTAssertEqual(out, "\u{1B}[3;4R\u{1B}[?62;22c")
    }

    func testTitleAndDECLineDrawing() {
        let t = Terminal(cols: 5, rows: 1)
        var title = ""
        t.onTitle = { title = $0 }
        t.feed("\u{1B}]0;my title\u{07}\u{1B}(0lqk\u{1B}(B")
        XCTAssertEqual(title, "my title")
        XCTAssertEqual(t.lines[0].text.prefix(3), "┌─┐")
    }

    func testInsertDeleteChars() {
        let t = Terminal(cols: 6, rows: 1)
        t.feed("abcdef\r\u{1B}[2C\u{1B}[2@")
        XCTAssertEqual(t.lines[0].text, "ab  cd")
        t.feed("\u{1B}[3P")
        XCTAssertEqual(t.lines[0].text, "abd   ")
    }

    func testResizeKeepsCursorVisible() {
        let t = Terminal(cols: 10, rows: 4)
        t.feed("a\r\nb\r\nc\r\nd")
        t.resize(cols: 10, rows: 2)
        XCTAssertEqual(screen(t), ["c", "d"])
        XCTAssertEqual(t.scrollback.count, 2)
        t.resize(cols: 10, rows: 4) // grows back by pulling from scrollback
        XCTAssertEqual(screen(t), ["a", "b", "c", "d"])
        XCTAssertEqual(t.cursorY, 3)
    }

    func testScrollbackRingEviction() {
        let t = Terminal(cols: 3, rows: 1, scrollbackLimit: 2)
        t.feed("1\r\n2\r\n3\r\n4")
        XCTAssertEqual(t.scrollback.count, 2)
        XCTAssertEqual(t.scrollback[0].text.trimmingCharacters(in: .whitespaces), "2")
        XCTAssertEqual(t.droppedLines, 1)
    }

    func testSelectionTextJoinsWrapped() {
        let t = Terminal(cols: 4, rows: 3)
        t.feed("abcdef\r\nxy")
        let s = Selection(anchor: t.stablePoint(viewportRow: 0, col: 0), head: t.stablePoint(viewportRow: 1, col: 3))
        // rows 0/1 hold "abcd" + "ef" (wrapped), then "xy" on row 2
        XCTAssertEqual(t.text(in: s), "abcdef")
        let all = Selection(anchor: t.stablePoint(viewportRow: 0, col: 0), head: t.stablePoint(viewportRow: 2, col: 3))
        XCTAssertEqual(t.text(in: all), "abcdef\nxy")
    }

    func testWordSelectionAndSearch() {
        let t = Terminal(cols: 20, rows: 2)
        t.feed("hello brave world\r\nBrave new")
        let w = t.wordSelection(at: t.stablePoint(viewportRow: 0, col: 8))
        XCTAssertEqual(t.text(in: w), "brave")
        XCTAssertEqual(t.search("brave").count, 2)
    }

    func testASCIIFastPathEdgeCases() {
        let t = Terminal(cols: 6, rows: 2)
        t.feed("漢字\r\u{1B}[1Cab")      // ASCII run starting on the spacer half of 漢
        XCTAssertEqual(t.lines[0].cells[0].ch, " ")
        XCTAssertEqual(t.lines[0].text, " ab   ") // overwriting either half of a wide char erases it (xterm)
        t.feed("\u{1B}[?7l\u{1B}[2;1Habcdefghij") // autowrap off: last column is overwritten
        XCTAssertEqual(t.lines[1].text, "abcdej")
        XCTAssertEqual(t.scrollback.count, 0)
    }

    func testHyperlink() {
        let t = Terminal(cols: 10, rows: 1)
        t.feed("\u{1B}]8;;https://x.dev\u{1B}\\ab\u{1B}]8;;\u{1B}\\c")
        XCTAssertEqual(t.hyperlinks[Int(t.lines[0].cells[0].link)], "https://x.dev")
        XCTAssertEqual(t.lines[0].cells[2].link, 0)
    }
}

final class InputTests: XCTestCase {
    func s(_ b: [UInt8]) -> String { String(bytes: b, encoding: .utf8)! }

    func testArrowKeys() {
        XCTAssertEqual(s(KeyEncoder.encode(.up, mods: [], appCursor: false)), "\u{1B}[A")
        XCTAssertEqual(s(KeyEncoder.encode(.up, mods: [], appCursor: true)), "\u{1B}OA")
        XCTAssertEqual(s(KeyEncoder.encode(.left, mods: [.ctrl], appCursor: false)), "\u{1B}[1;5D")
        XCTAssertEqual(s(KeyEncoder.encode(.f(5), mods: [.shift], appCursor: false)), "\u{1B}[15;2~")
        XCTAssertEqual(s(KeyEncoder.encode(.tab, mods: [.shift], appCursor: false)), "\u{1B}[Z")
    }

    func testControl() {
        XCTAssertEqual(KeyEncoder.control("c"), 3)
        XCTAssertEqual(KeyEncoder.control("["), 0x1B)
        XCTAssertEqual(KeyEncoder.control(" "), 0)
    }

    func testPaste() {
        XCTAssertEqual(s(KeyEncoder.paste("a\nb", bracketed: false)), "a\rb")
        XCTAssertEqual(s(KeyEncoder.paste("x\u{1B}[201~y", bracketed: true)), "\u{1B}[200~xy\u{1B}[201~")
        XCTAssertTrue(KeyEncoder.isUnsafePaste("rm -rf x\n", bracketed: false))
        XCTAssertFalse(KeyEncoder.isUnsafePaste("ls\n", bracketed: true))
    }

    func testMouse() {
        XCTAssertEqual(s(MouseEncoder.encode(button: .left, x: 4, y: 2, pressed: true, motion: false, mods: [], sgr: true)), "\u{1B}[<0;5;3M")
        XCTAssertEqual(s(MouseEncoder.encode(button: .wheelUp, x: 0, y: 0, pressed: true, motion: false, mods: [.ctrl], sgr: true)), "\u{1B}[<80;1;1M")
        XCTAssertEqual(MouseEncoder.encode(button: .left, x: 0, y: 0, pressed: false, motion: false, mods: [], sgr: false), [0x1B, 0x5B, 0x4D, 35, 33, 33])
    }
}

final class ThroughputTests: XCTestCase {
    /// Rough IO-path benchmark: plain text + SGR-heavy text through parser + terminal.
    func testThroughput() {
        let plain = Array(String(repeating: "the quick brown fox jumps over the lazy dog 0123456789\r\n", count: 20_000).utf8)
        let colored = Array(String(repeating: "\u{1B}[38;5;208mwarn\u{1B}[0m \u{1B}[1;32mok\u{1B}[0m 漢字 line\r\n", count: 20_000).utf8)
        for (name, data) in [("plain", plain), ("sgr+cjk", colored)] {
            let t = Terminal(cols: 120, rows: 40)
            let start = Date()
            t.feed(data)
            let secs = Date().timeIntervalSince(start)
            let mb = Double(data.count) / 1_048_576
            print(String(format: "THROUGHPUT %@: %.1f MB in %.3fs = %.1f MB/s", name, mb, secs, mb / secs))
        }
    }
}

final class NoopHandler: ParserHandler {
    var n = 0
    func print(_ s: Unicode.Scalar) { n &+= 1 }
    func execute(_ b: UInt8) {}
    func csiDispatch(params: [[Int]], intermediates: [UInt8], final: UInt8) {}
    func escDispatch(intermediates: [UInt8], final: UInt8) {}
    func oscDispatch(_ d: [UInt8]) {}
}

final class ProfileTests: XCTestCase {
    func testProfileLayers() {
        let line = "the quick brown fox jumps over the lazy dog 0123456789"
        let noNL = Array(String(repeating: line, count: 20_000).utf8)
        let withNL = Array(String(repeating: line + "\r\n", count: 20_000).utf8)
        func time(_ label: String, _ bytes: Int, _ f: () -> Void) {
            let s = Date(); f(); let d = Date().timeIntervalSince(s)
            print(String(format: "PROFILE %@: %.1f MB/s", label, Double(bytes) / 1_048_576 / d))
        }
        let p = Parser(); let h = NoopHandler(); p.handler = h
        time("parser-only", noNL.count) { noNL.withUnsafeBufferPointer { p.feed($0) } }
        let t1 = Terminal(cols: 120, rows: 40)
        time("terminal no-newline", noNL.count) { t1.feed(noNL) }
        let t2 = Terminal(cols: 120, rows: 40)
        time("terminal with-newline", withNL.count) { t2.feed(withNL) }
    }
}
