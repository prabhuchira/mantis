import XCTest
import AppKit
@testable import Mantis
@testable import MantisCore

final class ConfigTests: XCTestCase {
    func testDefaultsSerializeToHeaderOnly() {
        let text = Config().serialized()
        XCTAssertFalse(text.split(separator: "\n").contains { !$0.hasPrefix("#") && !$0.isEmpty }, text)
    }

    func testRoundTripEverySettingsField() {
        var c = Config()
        Theme.all[2].apply(to: &c)
        c.fontFamily = "Menlo"; c.fontSize = 15.5
        c.palette[200] = RGB(1, 2, 3)
        c.backgroundOpacity = 0.85; c.minimumContrast = 3.5
        c.windowPaddingX = 12; c.windowPaddingY = 4
        c.cursorStyle = .bar; c.cursorBlink = false; c.cursorTrail = false
        c.scrollbackLimit = 50_000; c.optionAsAlt = true; c.copyOnSelect = true
        c.confirmUnsafePaste = false; c.mouseHideWhileTyping = false
        c.command = "/bin/zsh -l"; c.waitAfterCommand = true; c.workingDirectory = "/tmp"
        c.windowWidth = 120; c.windowHeight = 40; c.unfocusedSplitOpacity = 0.5
        c.badge = "PROD {host}"; c.editor = "code -g {file}:{line}:{col}"
        c.highlightSpecs = [HighlightSpec(pattern: "ERROR|FAIL(ED)?", color: RGB(255, 0, 0)),
                            HighlightSpec(pattern: "a=b", color: RGB(0, 255, 0))] // '=' inside the regex
        c.effect = .synthwave; c.effectIntensity = 0.3; c.effectSpeed = 2; c.effectDensity = 0.25
        c.effectColor = RGB(0x12, 0x34, 0x56); c.effectPauseWhenInactive = false
        c.renderer = .coregraphics

        let back = Config.parse(c.serialized())
        XCTAssertEqual(back.errors, [])
        XCTAssertEqual(back.serialized(), c.serialized())
        XCTAssertEqual(back.fontSize, 15.5)
        XCTAssertEqual(back.palette[200], RGB(1, 2, 3))
        XCTAssertEqual(back.cursorStyle, .bar)
        XCTAssertEqual(back.highlightSpecs.map(\.pattern), ["ERROR|FAIL(ED)?", "a=b"])
        XCTAssertEqual(back.highlights.count, 2) // compiled rules follow the specs
        XCTAssertEqual(back.effect, .synthwave)
        XCTAssertEqual(back.effectColor, RGB(0x12, 0x34, 0x56))
        XCTAssertEqual(back.renderer, .coregraphics)
        XCTAssertEqual(Theme.matching(back)?.name, Theme.all[2].name)
    }

    func testInvalidValuesReportErrors() {
        let c = Config.parse("effect = lasers\nhighlight = ([=#ff0000\nfont-size = 2\nnonsense\neffect-intensity = 9")
        XCTAssertEqual(c.errors.count, 4)
        XCTAssertEqual(c.effect, .none)
        XCTAssertEqual(c.effectIntensity, 1) // clamped, not rejected
    }

    func testEveryEffectRendersWithoutCrashing() {
        let v = EffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
        for kind in EffectKind.allCases {
            v.configure(EffectSettings(kind: kind, density: 1))
            for _ in 0..<20 { v.advance(1.0 / 30) }
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            XCTAssertNotNil(rep.representation(using: .png, properties: [:]), kind.rawValue)
            // every real effect must actually paint something
            var painted = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 3) { for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.02 { painted += 1 }
            } }
            if kind == .none { XCTAssertEqual(painted, 0) } else { XCTAssertGreaterThan(painted, 50, "\(kind.rawValue) painted \(painted) samples") }
        }
    }
}
