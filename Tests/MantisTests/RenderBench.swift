import XCTest
import AppKit
import QuartzCore
@testable import Mantis
@testable import MantisCore

/// Rough render benchmark: time to draw one full frame of the text layer.
final class RenderBench: XCTestCase {
    func bench(_ name: String, _ setup: (TerminalView) -> Void) {
        var c = Config(); c.cursorBlink = false; c.renderer = .coregraphics
        let v = TerminalView(config: c)
        v.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        v.gridView.frame = v.bounds
        v.terminal.lock.lock(); v.terminal.resize(cols: 160, rows: 50); v.terminal.lock.unlock()
        setup(v)
        let rep = v.gridView.bitmapImageRepForCachingDisplay(in: v.gridView.bounds)!
        v.gridView.cacheDisplay(in: v.gridView.bounds, to: rep) // warm up
        let n = 30, start = Date()
        for _ in 0..<n { v.gridView.cacheDisplay(in: v.gridView.bounds, to: rep) }
        let ms = Date().timeIntervalSince(start) / Double(n) * 1000
        print(String(format: "RENDER %@: %.2f ms/frame (%.0f fps max)", name, ms, 1000 / ms))
    }

    func makeView(_ text: String) -> TerminalView {
        var c = Config(); c.cursorBlink = false; c.renderer = .coregraphics
        let v = TerminalView(config: c)
        v.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        v.gridView.frame = v.bounds
        v.terminal.lock.lock(); v.terminal.resize(cols: 160, rows: 50); v.terminal.feed(text); v.terminal.lock.unlock()
        let rep = v.gridView.bitmapImageRepForCachingDisplay(in: v.gridView.bounds)!
        v.gridView.cacheDisplay(in: v.gridView.bounds, to: rep) // full frame → records what is on screen
        return v
    }

    /// Output only invalidates rows that actually changed.
    func testDirtyRows() {
        let v = makeView("$ ls\r\nfile1 file2\r\n$ ")
        feed(v, "e"); v.invalidateChangedRows()
        XCTAssertEqual(v.lastDirtyRowCount, 1, "typing redraws one row")
        let rep = v.gridView.bitmapImageRepForCachingDisplay(in: v.gridView.bounds)!
        v.gridView.cacheDisplay(in: NSRect(x: 0, y: 0, width: 1400, height: 60), to: rep) // partial draw of rows 0-2
        feed(v, "cho hi\r\nhi\r\n$ "); v.invalidateChangedRows()
        XCTAssertEqual(v.lastDirtyRowCount, 3, "command + output + new prompt")
        v.invalidateChangedRows() // nothing changed since… but not yet drawn, so still dirty
        XCTAssertEqual(v.lastDirtyRowCount, 3)
        feed(v, String(repeating: "x\r\n", count: 60)); v.invalidateChangedRows()
        XCTAssertEqual(v.lastDirtyRowCount, 50, "scrolling redraws everything")
    }

    /// In a real window AppKit honours row invalidation: typing repaints one row.
    func testWindowPartialRedraw() {
        _ = NSApplication.shared
        let plain = String(repeating: "the quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnopqrstuvwxyz\r\n", count: 49)
        let v = makeView(plain)
        let w = NSWindow(contentRect: v.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = v; v.frame = w.contentView!.bounds; v.gridView.frame = v.bounds
        w.orderFrontRegardless()
        for _ in 0..<5 { pump(w) }
        v.redrawAll(); pump(w)
        XCTAssertEqual(v.lastPaintedRowCount, v.terminal.rows)
        defer { w.orderOut(nil) }
        // Typing and in-place output repaint one row; a cursor jump repaints the span between
        // old and new rows (AppKit merges the two row rects into one dirty rect).
        for (chunk, expected) in [("e", 1), ("c", 1), (" \u{1B}[31mred\u{1B}[0m", 1), ("\u{1B}[50;1H", 1), ("\u{8}x", 1)] {
            feed(v, chunk); v.invalidateChangedRows(); pump(w)
            XCTAssertEqual(v.lastPaintedRowCount, expected, chunk.debugDescription)
        }
        feed(v, "\u{1B}[5;3H"); v.invalidateChangedRows(); pump(w)
        XCTAssertEqual(v.lastPaintedRowCount, 46, "jump from row 50 to row 5")
        feed(v, "X"); v.invalidateChangedRows(); pump(w)
        XCTAssertEqual(v.lastPaintedRowCount, 1)
    }

    /// The Metal renderer must produce the same picture as CoreGraphics (modulo antialiasing).
    func testMetalMatchesCoreGraphics() throws {
        var text = "\u{1B}[1mbold\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[7minverse\u{1B}[0m \u{1B}[2mdim\u{1B}[0m plain\r\n"
        for i in 0..<16 { text += "\u{1B}[48;5;\(i)m  \u{1B}[0m" }
        text += "\r\n\u{1B}[38;2;255;100;50mtruecolor\u{1B}[0m \u{1B}[32mgreen\u{1B}[0m \u{1B}[41;37m alert \u{1B}[0m\r\n"
        text += "┌──┬──┐ ▁▂▃▄▅▆▇█ ░▒▓\r\n│ab│cd│ 漢字かな한글 é ñ 🙂🚀\r\n└──┴──┘ {}[]()<>|/\\ ~`'\"\r\n"
        func render(_ kind: RendererKind) throws -> NSBitmapImageRep {
            var c = Config(); c.cursorBlink = false; c.renderer = kind
            let v = TerminalView(config: c)
            v.frame = NSRect(x: 0, y: 0, width: 700, height: 200)
            v.terminal.lock.lock(); v.terminal.resize(cols: 80, rows: 10); v.terminal.feed(text); v.terminal.feed("\u{1B}[?25l"); v.terminal.lock.unlock()
            if kind == .metal, v.metalView == nil { throw XCTSkip("Metal unavailable") }
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        let cg = try render(.coregraphics), mtl = try render(.metal)
        XCTAssertEqual(cg.pixelsWide, mtl.pixelsWide)
        var total = 0.0, differing = 0, n = 0
        for y in 0..<cg.pixelsHigh { for x in 0..<cg.pixelsWide {
            let a = cg.colorAt(x: x, y: y)!, b = mtl.colorAt(x: x, y: y)!
            let d = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
            total += d; n += 1
            if d > 0.75 { differing += 1 } // grossly different pixel (missing/misplaced glyph or color)
        } }
        let mean = total / Double(n) / 3
        print(String(format: "RENDER metal vs cg: mean channel diff %.4f, grossly different pixels %.3f%%", mean, Double(differing) / Double(n) * 100))
        XCTAssertLessThan(mean, 0.01)
        XCTAssertLessThan(Double(differing) / Double(n), 0.002)
    }

    func testMetalFrameCost() throws {
        let plain = String(repeating: "the quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ ~!@#$%^&*()\r\n", count: 50)
        var colored = ""
        for i in 0..<50 { for j in 0..<16 { colored += "\u{1B}[38;5;\((i * 16 + j) % 256)mword\(j) " }; colored += "\u{1B}[0m\r\n" }
        for (name, text) in [("plain", plain), ("256-color", colored)] {
            var c = Config(); c.cursorBlink = false
            let v = TerminalView(config: c)
            v.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
            guard let mv = v.metalView else { throw XCTSkip("Metal unavailable") }
            v.terminal.lock.lock(); v.terminal.resize(cols: 160, rows: 50); v.terminal.feed(text); v.terminal.lock.unlock()
            _ = mv.renderImage() // warm the glyph atlas
            let n = 30
            var t0 = Date()
            for _ in 0..<n { _ = mv.buildQuads() }
            let cpu = Date().timeIntervalSince(t0) / Double(n) * 1000
            let full = mv.timeFrames(n)
            print(String(format: "RENDER metal %@: build quads %.2f ms (%d quads, %d glyphs in atlas); full frame incl. GPU %.2f ms",
                         name, cpu, mv.lastQuadCount, mv.atlas.count, full))
        }
    }

    /// The real on-screen path (updateLayer → drawable → present) produces the same pixels
    /// as the offscreen render used by the other tests.
    func testMetalOnScreenFrame() throws {
        _ = NSApplication.shared
        var c = Config(); c.cursorBlink = false
        let v = TerminalView(config: c)
        guard let mv = v.metalView else { throw XCTSkip("Metal unavailable") }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = v
        w.orderFrontRegardless()
        defer { w.orderOut(nil) }
        v.terminal.lock.lock(); v.terminal.feed("\u{1B}[?25l\u{1B}[1;32mon screen\u{1B}[0m 漢字 🙂 ┌─┐\r\n\u{1B}[44m blue bg \u{1B}[0m"); v.terminal.lock.unlock()
        for _ in 0..<5 { pump(w) }
        var captured: CGImage?
        let got = expectation(description: "frame captured")
        mv.captureNextFrame = { captured = $0; got.fulfill() }
        v.redrawAll()
        for _ in 0..<20 where captured == nil { pump(w) }
        wait(for: [got], timeout: 5)
        XCTAssertGreaterThan(mv.presentedFrames, 0)
        let live = try XCTUnwrap(captured), offscreen = try XCTUnwrap(mv.renderImage())
        XCTAssertEqual(live.width, offscreen.width); XCTAssertEqual(live.height, offscreen.height)
        let a = try XCTUnwrap(live.dataProvider?.data as Data?), b = try XCTUnwrap(offscreen.dataProvider?.data as Data?)
        XCTAssertTrue(a == b, "on-screen frame differs from offscreen render")
        XCTAssertTrue(a.contains { $0 != 0 }, "frame is blank")
    }

    func pump(_ w: NSWindow) {
        w.displayIfNeeded(); CATransaction.flush()
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
    }

    func feed(_ v: TerminalView, _ s: String) { v.terminal.lock.lock(); v.terminal.feed(s); v.terminal.lock.unlock() }

    func testRender() {
        let plain = String(repeating: "the quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ ~!@#$%^&*()\r\n", count: 50)
        var colored = ""
        for i in 0..<50 { for j in 0..<16 { colored += "\u{1B}[38;5;\((i * 16 + j) % 256)mword\(j) " }; colored += "\u{1B}[0m\r\n" }
        bench("plain", { feed($0, plain) })
        bench("256-color", { feed($0, colored) })
        bench("plain+3 highlight rules", { v in
            var c = v.config; c.highlightSpecs = [HighlightSpec(pattern: "fox", color: RGB(255, 0, 0)),
                                       HighlightSpec(pattern: "[0-9]+", color: RGB(0, 255, 0)),
                                       HighlightSpec(pattern: "ERROR|WARN", color: RGB(0, 0, 255))]
            v.applyConfig(c)
            feed(v, plain)
        })
        bench("plain+20 annotations", { v in
            feed(v, plain)
            v.terminal.lock.lock()
            for r in 0..<20 { v.annotations.add(Selection(anchor: v.terminal.stablePoint(viewportRow: r * 2, col: 4), head: v.terminal.stablePoint(viewportRow: r * 2, col: 40)), colorIndex: r % 5, in: v.terminal) }
            v.terminal.lock.unlock()
        })
    }
}
