import XCTest
@testable import MantisCore

/// Long-running loop for external profilers (only runs when MANTIS_SOAK is set).
final class ZZSoakTests: XCTestCase {
    func testSoak() throws {
        guard let kind = ProcessInfo.processInfo.environment["MANTIS_SOAK"] else { throw XCTSkip("set MANTIS_SOAK") }
        let line = kind == "cjk" ? "漢字かな한글 é ñ ü line\r\n" : "\u{1B}[38;5;208mwarn\u{1B}[0m \u{1B}[1;32mok\u{1B}[0m line\r\n"
        let data = Array(String(repeating: line, count: 20_000).utf8)
        let t = Terminal(cols: 120, rows: 40)
        let end = Date().addingTimeInterval(8)
        while Date() < end { t.feed(data) }
    }
}
