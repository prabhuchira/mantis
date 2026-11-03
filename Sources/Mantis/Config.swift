import AppKit
import MantisCore

/// Ghostty-style configuration: `key = value` lines in ~/.config/mantis/config,
/// overridable by `--key=value` CLI flags (Ghostty: src/config/Config.zig).
struct Config {
    var fontFamily = "SF Mono"
    var fontSize: CGFloat = 13
    var foreground = RGB(0xD6, 0xDA, 0xE3)
    var background = RGB(0x14, 0x16, 0x1B)
    var cursorColor = RGB(0xF2, 0xC1, 0x4E)
    var selectionBackground = RGB(0x33, 0x40, 0x5A)
    var palette = Palette.make256()
    var backgroundOpacity: CGFloat = 1.0
    var backgroundBlur = false
    var cursorStyle: Terminal.CursorShape = .block
    var cursorBlink = true
    var scrollbackLimit = 10_000
    var windowPaddingX: CGFloat = 8
    var windowPaddingY: CGFloat = 6
    var windowWidth = 100   // columns
    var windowHeight = 30   // rows
    var optionAsAlt = false
    var copyOnSelect = false
    var confirmUnsafePaste = true
    var mouseHideWhileTyping = true
    var command: String? = nil
    var waitAfterCommand = false
    var workingDirectory: String? = nil
    var minimumContrast: Double = 1.0
    var highlights: [HighlightRule] = []          // highlight = REGEX=#rrggbb (repeatable)
    var editor: String? = nil                     // editor = code -g {file}:{line}:{col}
    var badge: String? = nil                      // badge = {host}  (tokens: {host} {user} {cwd} {title})
    var unfocusedSplitOpacity: CGFloat = 0.7      // dims inactive splits
    var cursorTrail = true
    var errors: [String] = []

    static var path: String { NSHomeDirectory() + "/.config/mantis/config" }

    static func load(arguments: [String] = CommandLine.arguments) -> Config {
        var c = Config()
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { c.errors.append("line \(n + 1): missing '='"); continue }
                let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !c.set(k, v) { c.errors.append("line \(n + 1): invalid '\(k) = \(v)'") }
            }
        }
        var i = 1
        while i < arguments.count {
            let a = arguments[i]
            if a == "-e" { // like `ghostty -e cmd args...`
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

    /// Returns false if the key/value is not understood.
    mutating func set(_ k: String, _ v: String) -> Bool {
        switch k {
        case "font-family": fontFamily = v
        case "font-size": guard let f = Double(v), f > 3 else { return false }; fontSize = CGFloat(f)
        case "foreground": guard let c = RGB(hex: v) else { return false }; foreground = c
        case "background": guard let c = RGB(hex: v) else { return false }; background = c
        case "cursor-color": guard let c = RGB(hex: v) else { return false }; cursorColor = c
        case "selection-background": guard let c = RGB(hex: v) else { return false }; selectionBackground = c
        case "palette": // palette = 3=#ffcc00
            let f = v.split(separator: "=", maxSplits: 1)
            guard f.count == 2, let i = Int(f[0].trimmingCharacters(in: .whitespaces)), (0..<256).contains(i),
                  let c = RGB(hex: String(f[1])) else { return false }
            palette[i] = c
        case "background-opacity": guard let d = Double(v) else { return false }; backgroundOpacity = CGFloat(max(0.05, min(1, d)))
        case "background-blur": guard let b = bool(v) else { return false }; backgroundBlur = b
        case "cursor-style":
            switch v { case "block": cursorStyle = .block; case "bar": cursorStyle = .bar; case "underline": cursorStyle = .underline; default: return false }
        case "cursor-style-blink": guard let b = bool(v) else { return false }; cursorBlink = b
        case "scrollback-limit": guard let n = Int(v), n >= 0 else { return false }; scrollbackLimit = n
        case "window-padding-x": guard let n = Double(v) else { return false }; windowPaddingX = CGFloat(n)
        case "window-padding-y": guard let n = Double(v) else { return false }; windowPaddingY = CGFloat(n)
        case "window-width": guard let n = Int(v), n > 10 else { return false }; windowWidth = n
        case "window-height": guard let n = Int(v), n > 4 else { return false }; windowHeight = n
        case "macos-option-as-alt": guard let b = bool(v) else { return false }; optionAsAlt = b
        case "copy-on-select": guard let b = bool(v) else { return false }; copyOnSelect = b
        case "clipboard-paste-protection": guard let b = bool(v) else { return false }; confirmUnsafePaste = b
        case "mouse-hide-while-typing": guard let b = bool(v) else { return false }; mouseHideWhileTyping = b
        case "command": command = v
        case "wait-after-command": guard let b = bool(v) else { return false }; waitAfterCommand = b
        case "working-directory": workingDirectory = (v as NSString).expandingTildeInPath
        case "highlight": guard let r = HighlightRule(spec: v) else { return false }; highlights.append(r)
        case "editor": editor = v.isEmpty ? nil : v
        case "badge": badge = v.isEmpty ? nil : v
        case "unfocused-split-opacity": guard let d = Double(v) else { return false }; unfocusedSplitOpacity = CGFloat(max(0.15, min(1, d)))
        case "cursor-trail": guard let b = bool(v) else { return false }; cursorTrail = b
        case "minimum-contrast": guard let d = Double(v), d >= 1 else { return false }; minimumContrast = min(21, d)
        default: return false
        }
        return true
    }

    func makeFont(size: CGFloat? = nil) -> NSFont {
        let s = size ?? fontSize
        if let f = NSFont(name: fontFamily, size: s) { return f }
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
}

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var cgColor: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }

    var luminance: Double {
        func ch(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)
    }

    func contrast(with o: RGB) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Nudge toward black/white until the WCAG contrast ratio is met (Ghostty: minimum-contrast).
    func ensuringContrast(against bg: RGB, ratio: Double) -> RGB {
        guard ratio > 1, contrast(with: bg) < ratio else { return self }
        let target = bg.luminance > 0.5 ? RGB(0, 0, 0) : RGB(255, 255, 255)
        var t = 0.0
        var c = self
        while t < 1 && c.contrast(with: bg) < ratio { t += 0.05; c = blended(with: target, t) }
        return c
    }
}
