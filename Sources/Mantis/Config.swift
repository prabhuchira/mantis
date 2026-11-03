import AppKit
import MantisCore

/// An editable highlight rule (`highlight = REGEX=#rrggbb`).
struct HighlightSpec: Identifiable, Equatable {
    let id = UUID()
    var pattern: String
    var color: RGB
    var isValid: Bool { !pattern.isEmpty && (try? NSRegularExpression(pattern: pattern)) != nil }
    static func == (a: HighlightSpec, b: HighlightSpec) -> Bool { a.pattern == b.pattern && a.color == b.color }
}

/// Configuration: `key = value` lines in ~/.config/mantis/config,
/// overridable by `--key=value` CLI flags.
/// The Settings window edits this struct and writes it back with `serialized()`.
struct Config {
    // Appearance
    var fontFamily = "SF Mono"
    var fontSize: CGFloat = 13
    var foreground = RGB(0xD6, 0xDA, 0xE3)
    var background = RGB(0x14, 0x16, 0x1B)
    var cursorColor = RGB(0xF2, 0xC1, 0x4E)
    var selectionBackground = RGB(0x33, 0x40, 0x5A)
    var palette = Palette.make256()
    var backgroundOpacity: CGFloat = 1.0
    var minimumContrast: Double = 1.0
    var windowPaddingX: CGFloat = 8
    var windowPaddingY: CGFloat = 6
    // Cursor
    var cursorStyle: Terminal.CursorShape = .block
    var cursorBlink = true
    var cursorTrail = true
    // Terminal behaviour
    var scrollbackLimit = 10_000
    var optionAsAlt = false
    var copyOnSelect = false
    var confirmUnsafePaste = true
    var mouseHideWhileTyping = true
    var command: String? = nil
    var waitAfterCommand = false
    var shellColors = true                        // CLICOLOR/LSCOLORS + colored stock zsh prompt
    var workingDirectory: String? = nil
    // Window & splits
    var windowWidth = 100   // columns
    var windowHeight = 30   // rows
    var unfocusedSplitOpacity: CGFloat = 0.7
    var badge: String? = nil                      // tokens: {host} {user} {cwd} {title}
    // Links & highlights
    var editor: String? = nil                     // e.g. code -g {file}:{line}:{col}
    var highlightSpecs: [HighlightSpec] = [] { didSet { recompileHighlights() } }
    private(set) var highlights: [HighlightRule] = []
    // Effects
    var effect: EffectKind = .none
    var effectIntensity: CGFloat = 0.45
    var effectSpeed: CGFloat = 1.0
    var effectDensity: CGFloat = 0.6
    var effectColor: RGB? = nil                   // nil = the effect's own palette
    var effectPauseWhenInactive = true
    // Rendering
    var renderer: RendererKind = .metal

    var errors: [String] = []

    static var path: String { NSHomeDirectory() + "/.config/mantis/config" }

    private mutating func recompileHighlights() {
        highlights = highlightSpecs.compactMap { HighlightRule(spec: "\($0.pattern)=#\($0.color.hex)") }
    }

    // MARK: - Loading

    /// Parses config-file text (does not touch disk; used by load and tests).
    static func parse(_ text: String, into base: Config = Config()) -> Config {
        var c = base
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { c.errors.append("line \(n + 1): missing '='"); continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !c.set(k, v) { c.errors.append("line \(n + 1): invalid '\(k) = \(v)'") }
        }
        return c
    }

    /// The file only (what the Settings window edits).
    static func loadFile() -> Config {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return Config() }
        return parse(text)
    }

    /// File + CLI flags (what new terminals use at launch).
    static func load(arguments: [String] = CommandLine.arguments) -> Config {
        var c = loadFile()
        var i = 1
        while i < arguments.count {
            let a = arguments[i]
            if a == "-e" { // `-e cmd args...` runs a command instead of the shell
                c.command = arguments[(i + 1)...].joined(separator: " ")
                c.waitAfterCommand = true
                break
            }
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                let k = String(a[a.index(a.startIndex, offsetBy: 2)..<eq])
                if !c.set(k, String(a[a.index(after: eq)...])) { c.errors.append("flag \(a) invalid") }
            }
            i += 1
        }
        return c
    }

    private func bool(_ v: String) -> Bool? { ["true", "yes", "1"].contains(v) ? true : ["false", "no", "0"].contains(v) ? false : nil }
    private func num(_ v: String, _ lo: Double, _ hi: Double) -> CGFloat? { Double(v).map { CGFloat(max(lo, min(hi, $0))) } }

    /// Returns false if the key/value is not understood.
    mutating func set(_ k: String, _ v: String) -> Bool {
        switch k {
        case "font-family": fontFamily = v
        case "font-size": guard let f = Double(v), f > 3 else { return false }; fontSize = CGFloat(min(f, 72))
        case "foreground": guard let c = RGB(hex: v) else { return false }; foreground = c
        case "background": guard let c = RGB(hex: v) else { return false }; background = c
        case "cursor-color": guard let c = RGB(hex: v) else { return false }; cursorColor = c
        case "selection-background": guard let c = RGB(hex: v) else { return false }; selectionBackground = c
        case "palette": // palette = 3=#ffcc00
            let f = v.split(separator: "=", maxSplits: 1)
            guard f.count == 2, let i = Int(f[0].trimmingCharacters(in: .whitespaces)), (0..<256).contains(i),
                  let c = RGB(hex: String(f[1])) else { return false }
            palette[i] = c
        case "background-opacity": guard let d = num(v, 0.05, 1) else { return false }; backgroundOpacity = d
        case "background-blur": guard bool(v) != nil else { return false } // accepted but not implemented yet
        case "cursor-style":
            switch v { case "block": cursorStyle = .block; case "bar": cursorStyle = .bar; case "underline": cursorStyle = .underline; default: return false }
        case "cursor-style-blink": guard let b = bool(v) else { return false }; cursorBlink = b
        case "cursor-trail": guard let b = bool(v) else { return false }; cursorTrail = b
        case "scrollback-limit": guard let n = Int(v), n >= 0 else { return false }; scrollbackLimit = n
        case "window-padding-x": guard let n = num(v, 0, 100) else { return false }; windowPaddingX = n
        case "window-padding-y": guard let n = num(v, 0, 100) else { return false }; windowPaddingY = n
        case "window-width": guard let n = Int(v), n > 10 else { return false }; windowWidth = n
        case "window-height": guard let n = Int(v), n > 4 else { return false }; windowHeight = n
        case "macos-option-as-alt": guard let b = bool(v) else { return false }; optionAsAlt = b
        case "copy-on-select": guard let b = bool(v) else { return false }; copyOnSelect = b
        case "clipboard-paste-protection": guard let b = bool(v) else { return false }; confirmUnsafePaste = b
        case "mouse-hide-while-typing": guard let b = bool(v) else { return false }; mouseHideWhileTyping = b
        case "command": command = v.isEmpty ? nil : v
        case "wait-after-command": guard let b = bool(v) else { return false }; waitAfterCommand = b
        case "shell-colors": guard let b = bool(v) else { return false }; shellColors = b
        case "working-directory": workingDirectory = v.isEmpty ? nil : (v as NSString).expandingTildeInPath
        case "highlight":
            guard let eq = v.lastIndex(of: "="), let c = RGB(hex: String(v[v.index(after: eq)...])) else { return false }
            let spec = HighlightSpec(pattern: String(v[..<eq]), color: c)
            guard spec.isValid else { return false }
            highlightSpecs.append(spec)
        case "editor": editor = v.isEmpty ? nil : v
        case "badge": badge = v.isEmpty ? nil : v
        case "unfocused-split-opacity": guard let d = num(v, 0.15, 1) else { return false }; unfocusedSplitOpacity = d
        case "minimum-contrast": guard let d = Double(v), d >= 1 else { return false }; minimumContrast = min(21, d)
        case "effect": guard let e = EffectKind(rawValue: v) else { return false }; effect = e
        case "effect-intensity": guard let d = num(v, 0, 1) else { return false }; effectIntensity = d
        case "effect-speed": guard let d = num(v, 0.1, 4) else { return false }; effectSpeed = d
        case "effect-density": guard let d = num(v, 0.05, 1) else { return false }; effectDensity = d
        case "effect-color":
            if v.isEmpty || v == "auto" { effectColor = nil } else { guard let c = RGB(hex: v) else { return false }; effectColor = c }
        case "effect-pause-when-inactive": guard let b = bool(v) else { return false }; effectPauseWhenInactive = b
        case "renderer": guard let r = RendererKind(rawValue: v) else { return false }; renderer = r
        default: return false
        }
        return true
    }

    // MARK: - Saving

    /// Config-file text containing only the values that differ from defaults.
    func serialized() -> String {
        let d = Config()
        var out = ["# Mantis configuration — written by Settings (⌘,).",
                   "# Syntax: key = value. Hand edits are fine; reload with ⇧⌘,.", ""]
        func add(_ k: String, _ v: String) { out.append("\(k) = \(v)") }
        func n(_ x: CGFloat) -> String { x == x.rounded() ? String(Int(x)) : String(format: "%.2f", Double(x)) }
        if fontFamily != d.fontFamily { add("font-family", fontFamily) }
        if fontSize != d.fontSize { add("font-size", n(fontSize)) }
        if foreground != d.foreground { add("foreground", "#" + foreground.hex) }
        if background != d.background { add("background", "#" + background.hex) }
        if cursorColor != d.cursorColor { add("cursor-color", "#" + cursorColor.hex) }
        if selectionBackground != d.selectionBackground { add("selection-background", "#" + selectionBackground.hex) }
        for i in 0..<256 where palette[i] != d.palette[i] { add("palette", "\(i)=#\(palette[i].hex)") }
        if backgroundOpacity != d.backgroundOpacity { add("background-opacity", n(backgroundOpacity)) }
        if minimumContrast != d.minimumContrast { add("minimum-contrast", n(CGFloat(minimumContrast))) }
        if windowPaddingX != d.windowPaddingX { add("window-padding-x", n(windowPaddingX)) }
        if windowPaddingY != d.windowPaddingY { add("window-padding-y", n(windowPaddingY)) }
        if cursorStyle != d.cursorStyle { add("cursor-style", cursorStyle == .bar ? "bar" : cursorStyle == .underline ? "underline" : "block") }
        if cursorBlink != d.cursorBlink { add("cursor-style-blink", "\(cursorBlink)") }
        if cursorTrail != d.cursorTrail { add("cursor-trail", "\(cursorTrail)") }
        if scrollbackLimit != d.scrollbackLimit { add("scrollback-limit", "\(scrollbackLimit)") }
        if optionAsAlt != d.optionAsAlt { add("macos-option-as-alt", "\(optionAsAlt)") }
        if copyOnSelect != d.copyOnSelect { add("copy-on-select", "\(copyOnSelect)") }
        if confirmUnsafePaste != d.confirmUnsafePaste { add("clipboard-paste-protection", "\(confirmUnsafePaste)") }
        if mouseHideWhileTyping != d.mouseHideWhileTyping { add("mouse-hide-while-typing", "\(mouseHideWhileTyping)") }
        if let command { add("command", command) }
        if waitAfterCommand != d.waitAfterCommand { add("wait-after-command", "\(waitAfterCommand)") }
        if shellColors != d.shellColors { add("shell-colors", "\(shellColors)") }
        if let workingDirectory { add("working-directory", workingDirectory) }
        if windowWidth != d.windowWidth { add("window-width", "\(windowWidth)") }
        if windowHeight != d.windowHeight { add("window-height", "\(windowHeight)") }
        if unfocusedSplitOpacity != d.unfocusedSplitOpacity { add("unfocused-split-opacity", n(unfocusedSplitOpacity)) }
        if let badge { add("badge", badge) }
        if let editor { add("editor", editor) }
        for h in highlightSpecs where h.isValid { add("highlight", "\(h.pattern)=#\(h.color.hex)") }
        if effect != d.effect { add("effect", effect.rawValue) }
        if effectIntensity != d.effectIntensity { add("effect-intensity", n(effectIntensity)) }
        if effectSpeed != d.effectSpeed { add("effect-speed", n(effectSpeed)) }
        if effectDensity != d.effectDensity { add("effect-density", n(effectDensity)) }
        if let effectColor { add("effect-color", "#" + effectColor.hex) }
        if effectPauseWhenInactive != d.effectPauseWhenInactive { add("effect-pause-when-inactive", "\(effectPauseWhenInactive)") }
        if renderer != d.renderer { add("renderer", renderer.rawValue) }
        return out.joined(separator: "\n") + "\n"
    }

    /// Writes the file, keeping a one-time backup of a hand-written original.
    func save() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: (Config.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let backup = Config.path + ".bak"
        if fm.fileExists(atPath: Config.path), !fm.fileExists(atPath: backup),
           let old = try? String(contentsOfFile: Config.path, encoding: .utf8), !old.hasPrefix("# Mantis configuration — written by Settings") {
            try? fm.copyItem(atPath: Config.path, toPath: backup)
        }
        try serialized().write(toFile: Config.path, atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    func makeFont(size: CGFloat? = nil) -> NSFont {
        let s = size ?? fontSize
        if let f = NSFont(name: fontFamily, size: s) { return f }
        if let f = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: s) { return f }
        if fontFamily == "SF Mono" { return NSFont.monospacedSystemFont(ofSize: s, weight: .regular) }
        return NSFont(name: "Menlo", size: s) ?? NSFont.monospacedSystemFont(ofSize: s, weight: .regular)
    }

    func apply(to t: Terminal) {
        t.defaultFG = foreground
        t.defaultBG = background
        t.cursorColor = cursorColor
        t.palette = palette
        t.cursorShape = cursorStyle
        t.cursorBlink = cursorBlink
    }

    var effectSettings: EffectSettings {
        EffectSettings(kind: effect, intensity: effectIntensity, speed: effectSpeed, density: effectDensity,
                       color: effectColor, pauseWhenInactive: effectPauseWhenInactive, background: background)
    }
}

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var cgColor: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var hex: String { String(format: "%02x%02x%02x", r, g, b) }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        func b(_ x: CGFloat) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded()))) }
        self.init(b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }

    var luminance: Double {
        func ch(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    }

    func contrast(with o: RGB) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Nudge toward black/white until the WCAG contrast ratio is met.
    func ensuringContrast(against bg: RGB, ratio: Double) -> RGB {
        guard ratio > 1, contrast(with: bg) < ratio else { return self }
        let target = bg.luminance > 0.5 ? RGB(0, 0, 0) : RGB(255, 255, 255)
        var t = 0.0
        var c = self
        while t < 1 && c.contrast(with: bg) < ratio { t += 0.05; c = blended(with: target, t) }
        return c
    }
}

/// How the cell grid is drawn. Metal (GPU glyph atlas) is the
/// default; CoreGraphics is the fallback and is used automatically if Metal is unavailable.
enum RendererKind: String, CaseIterable {
    case metal, coregraphics
    var label: String { self == .metal ? "Metal (GPU)" : "CoreGraphics (CPU)" }
}
