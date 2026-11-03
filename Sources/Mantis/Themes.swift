import MantisCore

/// Built-in color themes (original palettes made for Mantis).
struct Theme: Identifiable {
    let name: String
    let background: RGB
    let foreground: RGB
    let cursor: RGB
    let selection: RGB
    let ansi: [RGB] // 16 colors
    var id: String { name }

    private static func h(_ s: String) -> RGB { RGB(hex: s)! }
    private static func a(_ s: [String]) -> [RGB] { s.map(h) }

    static let all: [Theme] = [
        Theme(name: "Mantis Night", background: h("14161b"), foreground: h("d6dae3"), cursor: h("f2c14e"), selection: h("33405a"),
              ansi: Palette.base16),
        Theme(name: "Mantis Day", background: h("f7f6f2"), foreground: h("2b2d33"), cursor: h("d9480f"), selection: h("cfdcf0"),
              ansi: a(["2b2d33", "c92a3a", "2f8a3c", "a8710a", "1f63c2", "8e3fb0", "11808a", "d8d8d8",
                       "6b6f7a", "e0485a", "3fa64e", "c78a14", "3a7fe0", "a957cc", "1aa0ab", "ffffff"])),
        Theme(name: "Jade Grove", background: h("0f1a17"), foreground: h("cfe8dc"), cursor: h("7dffb3"), selection: h("1f3d33"),
              ansi: a(["16231f", "e5636f", "5fd38d", "d9c86a", "5aa9d6", "b98ae0", "4fd1c2", "c2d8ce",
                       "3b5249", "f07f89", "80e6a8", "e8da8a", "7dc0e6", "cfa6ef", "73e3d6", "eefaf4"])),
        Theme(name: "Ember", background: h("1c1210"), foreground: h("f0dccd"), cursor: h("ff8a3d"), selection: h("4a2a22"),
              ansi: a(["2a1c18", "ef5f4a", "a6c46a", "f2a541", "6f9fd8", "d97aa8", "6cc3b4", "dcc8ba",
                       "5c4038", "ff7f68", "bcd884", "ffbe63", "8db6e6", "e898bd", "8ad6c8", "fff3ea"])),
        Theme(name: "Abyss", background: h("0a0f1f"), foreground: h("c9d4ff"), cursor: h("5ef0ff"), selection: h("1d2a52"),
              ansi: a(["111933", "ff5c8a", "5cf2a6", "ffd166", "4d8bff", "a77bff", "3fe0ff", "c0caf0",
                       "2c3966", "ff7ea2", "7cf7bb", "ffdd8a", "75a6ff", "bf9dff", "6ce9ff", "eef2ff"])),
        Theme(name: "Paper Ink", background: h("fbf8ef"), foreground: h("383a42"), cursor: h("3a56d4"), selection: h("e4dcc4"),
              ansi: a(["383a42", "b8352b", "4d7a2a", "8f6a10", "2f56b0", "8a3fa0", "1f7a7a", "dcd6c4",
                       "7d7f87", "d24a3f", "64953a", "ad8418", "4672cc", "a456bc", "2b9494", "fffdf6"])),
        Theme(name: "Phosphor", background: h("061006"), foreground: h("7dff8a"), cursor: h("b6ffbc"), selection: h("164a1c"),
              ansi: a(["0b1a0b", "4fd65c", "7dff8a", "a8ff9e", "3fb84b", "62e070", "8cff99", "7dff8a",
                       "1f5a24", "6ee87a", "a2ffab", "c8ffc0", "56cc62", "84f090", "b0ffb6", "d8ffdc"])),
    ]

    func apply(to c: inout Config) {
        c.background = background
        c.foreground = foreground
        c.cursorColor = cursor
        c.selectionBackground = selection
        for i in 0..<16 { c.palette[i] = ansi[i] }
    }

    /// Theme whose colors match the config exactly, if any.
    static func matching(_ c: Config) -> Theme? {
        all.first { $0.background == c.background && $0.foreground == c.foreground && Array(c.palette[0..<16]) == $0.ansi }
    }
}
