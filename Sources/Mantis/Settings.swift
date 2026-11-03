import AppKit
import SwiftUI
import MantisCore

// MARK: - Model

/// Single source of truth for the Settings window. Every edit is applied live to
/// all open terminals and saved (debounced) to ~/.config/mantis/config.
final class SettingsModel: ObservableObject {
    @Published var config: Config { didSet { changed() } }
    @Published var tab = 0
    @Published var status = ""
    var onApply: ((Config) -> Void)?
    private var saveWork: DispatchWorkItem?
    private var suppressSave = false

    init(config: Config = Config.loadFile()) { self.config = config }

    private func changed() {
        onApply?(config)
        guard !suppressSave else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func save() {
        do { try config.save(); status = "Saved to \(Config.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" }
        catch { status = "Save failed: \(error.localizedDescription)" }
    }

    /// Re-read the file (e.g. after hand edits) without writing it back.
    func reloadFromDisk() {
        suppressSave = true
        config = Config.loadFile()
        suppressSave = false
        status = config.errors.isEmpty ? "Reloaded from disk" : "Reloaded with \(config.errors.count) error(s): " + config.errors.joined(separator: "; ")
    }

    func resetToDefaults() { config = Config(); status = "Reset to defaults" }

    static let monospacedFamilies: [String] = {
        let fm = NSFontManager.shared
        let mono = fm.availableFontFamilies.filter { fam in
            guard let first = fm.availableMembers(ofFontFamily: fam)?.first, let name = first[0] as? String,
                  let f = NSFont(name: name, size: 12) else { return false }
            return f.isFixedPitch || fam.localizedCaseInsensitiveContains("mono") || fam.localizedCaseInsensitiveContains("code")
        }
        return ["SF Mono"] + mono.filter { $0 != "SF Mono" }.sorted()
    }()
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        let host = NSHostingController(rootView: SettingsView(model: model))
        let w = NSWindow(contentViewController: host)
        w.title = "Mantis Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 780, height: 640))
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) { model.save() }
}

// MARK: - Binding helpers

private func colorBinding(_ b: Binding<RGB>) -> Binding<Color> {
    Binding(get: { Color(nsColor: b.wrappedValue.nsColor) }, set: { b.wrappedValue = RGB(nsColor: NSColor($0)) })
}

private func optionalText(_ b: Binding<String?>) -> Binding<String> {
    Binding(get: { b.wrappedValue ?? "" }, set: { b.wrappedValue = $0.isEmpty ? nil : $0 })
}

private func intText(_ b: Binding<Int>) -> Binding<String> {
    Binding(get: { String(b.wrappedValue) }, set: { if let n = Int($0.filter(\.isNumber)) { b.wrappedValue = n } })
}

private struct SliderRow: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var step: CGFloat = 0.01
    var format = "%.2f"
    var help: String? = nil
    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(String(format: format, Double(value))).monospacedDigit().frame(width: 52, alignment: .trailing)
            }
        } label: {
            Text(title)
            if let help { Text(help).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $model.tab) {
                AppearanceTab(model: model).tabItem { Label("Appearance", systemImage: "paintpalette") }.tag(0)
                CursorTab(model: model).tabItem { Label("Cursor", systemImage: "character.cursor.ibeam") }.tag(1)
                EffectsTab(model: model).tabItem { Label("Effects", systemImage: "sparkles") }.tag(2)
                TerminalTab(model: model).tabItem { Label("Terminal", systemImage: "terminal") }.tag(3)
                WindowTab(model: model).tabItem { Label("Window", systemImage: "macwindow.on.rectangle") }.tag(4)
                HighlightsTab(model: model).tabItem { Label("Highlights", systemImage: "highlighter") }.tag(5)
                AdvancedTab(model: model).tabItem { Label("Advanced", systemImage: "gearshape.2") }.tag(6)
            }
            Divider()
            HStack {
                Image(systemName: "bolt.fill").foregroundStyle(.secondary)
                Text("Changes apply instantly to open terminals.").foregroundStyle(.secondary)
                Spacer()
                Text(model.status).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(minWidth: 780, minHeight: 640)
    }
}

// MARK: - Live terminal preview

struct TerminalPreview: View {
    let config: Config
    var showEffect = true

    private var font: Font {
        config.fontFamily == "SF Mono" ? .system(size: config.fontSize, design: .monospaced) : .custom(config.fontFamily, size: config.fontSize)
    }
    private func c(_ i: Int) -> Color { Color(nsColor: config.palette[i].nsColor) }
    private var fg: Color { Color(nsColor: config.foreground.nsColor) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: config.background.nsColor).opacity(Double(config.backgroundOpacity))
            if showEffect && config.effect != .none && !config.effect.isOverlay { EffectPreview(settings: config.effectSettings) }
            VStack(alignment: .leading, spacing: 1) {
                (Text("mantis").foregroundColor(c(2)) + Text(" ~/src ").foregroundColor(c(4)) + Text("❯ ").foregroundColor(c(5)) + Text("make test").foregroundColor(fg))
                (Text("✔ ").foregroundColor(c(2)) + Text("38 passed ").foregroundColor(fg) + Text("2 skipped").foregroundColor(c(3)))
                (Text("✘ ").foregroundColor(c(1)) + Text("ERROR").foregroundColor(highlight("ERROR") ?? c(1)) + Text(" Parser.swift:42:7").foregroundColor(fg).underline())
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { i in Rectangle().fill(c(i)).frame(width: 18, height: 10) }
                    Text(" ")
                    ForEach(8..<16, id: \.self) { i in Rectangle().fill(c(i)).frame(width: 18, height: 10) }
                }
                HStack(spacing: 0) {
                    Text("❯ ").foregroundColor(c(5))
                    Text(" ").background(Color(nsColor: config.selectionBackground.nsColor)).foregroundColor(fg)
                    Text("selected").foregroundColor(fg).background(Color(nsColor: config.selectionBackground.nsColor))
                    Text(" ")
                    Rectangle().fill(Color(nsColor: config.cursorColor.nsColor))
                        .frame(width: config.cursorStyle == .bar ? 2 : config.fontSize * 0.6,
                               height: config.cursorStyle == .underline ? 2 : config.fontSize * 1.2)
                        .frame(height: config.fontSize * 1.2, alignment: config.cursorStyle == .underline ? .bottom : .center)
                }
            }
            .font(font)
            .padding(.horizontal, config.windowPaddingX).padding(.vertical, config.windowPaddingY)
            if showEffect && config.effect.isOverlay { EffectPreview(settings: config.effectSettings) }
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
    }

    private func highlight(_ s: String) -> Color? {
        config.highlights.first { $0.regex.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil }
            .map { Color(nsColor: $0.color.nsColor) }
    }
}

struct EffectPreview: NSViewRepresentable {
    let settings: EffectSettings
    func makeNSView(context: Context) -> EffectView { let v = EffectView(frame: .zero); v.configure(settings); return v }
    func updateNSView(_ v: EffectView, context: Context) { if v.settings != settings { v.configure(settings) } }
}

// MARK: - Tabs

struct AppearanceTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section { TerminalPreview(config: model.config) }
            Section("Theme") {
                Picker("Preset", selection: Binding(
                    get: { Theme.matching(model.config)?.name ?? "Custom" },
                    set: { name in if let t = Theme.all.first(where: { $0.name == name }) { var c = model.config; t.apply(to: &c); model.config = c } })) {
                    ForEach(Theme.all) { Text($0.name).tag($0.name) }
                    if Theme.matching(model.config) == nil { Text("Custom").tag("Custom") }
                }
            }
            Section("Font") {
                Picker("Family", selection: $model.config.fontFamily) {
                    ForEach(SettingsModel.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                    if !SettingsModel.monospacedFamilies.contains(model.config.fontFamily) {
                        Text(model.config.fontFamily).tag(model.config.fontFamily)
                    }
                }
                SliderRow(title: "Size", value: $model.config.fontSize, range: 8...32, step: 0.5, format: "%.1f pt")
            }
            Section("Colors") {
                ColorPicker("Background", selection: colorBinding($model.config.background), supportsOpacity: false)
                ColorPicker("Foreground", selection: colorBinding($model.config.foreground), supportsOpacity: false)
                ColorPicker("Selection", selection: colorBinding($model.config.selectionBackground), supportsOpacity: false)
                ColorPicker("Cursor", selection: colorBinding($model.config.cursorColor), supportsOpacity: false)
                SliderRow(title: "Background opacity", value: $model.config.backgroundOpacity, range: 0.3...1)
                SliderRow(title: "Minimum contrast", value: Binding(get: { CGFloat(model.config.minimumContrast) },
                                                                    set: { model.config.minimumContrast = Double($0) }),
                          range: 1...7, step: 0.1, format: "%.1f:1", help: "Brightens text that is too close to its background (WCAG ratio).")
            }
            Section("ANSI palette") {
                PaletteGrid(model: model)
            }
            Section("Padding") {
                SliderRow(title: "Horizontal", value: $model.config.windowPaddingX, range: 0...40, step: 1, format: "%.0f pt")
                SliderRow(title: "Vertical", value: $model.config.windowPaddingY, range: 0...40, step: 1, format: "%.0f pt")
            }
        }
        .formStyle(.grouped)
    }
}

struct PaletteGrid: View {
    @ObservedObject var model: SettingsModel
    private let names = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<2) { row in
                HStack(spacing: 10) {
                    Text(row == 0 ? "Normal" : "Bright").frame(width: 50, alignment: .leading).foregroundStyle(.secondary)
                    ForEach(0..<8) { col in
                        let i = row * 8 + col
                        VStack(spacing: 2) {
                            ColorPicker("", selection: colorBinding($model.config.palette[i]), supportsOpacity: false).labelsHidden()
                            Text("\(i)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .help("\(row == 0 ? "" : "Bright ")\(names[col]) (color \(i))")
                    }
                }
            }
            Button("Reset palette to theme") {
                var c = model.config
                let t = Theme.all.first { $0.background == c.background } ?? Theme.all[0]
                for i in 0..<16 { c.palette[i] = t.ansi[i] }
                model.config = c
            }.controlSize(.small)
        }
    }
}

struct CursorTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section { TerminalPreview(config: model.config, showEffect: false) }
            Section("Shape") {
                Picker("Style", selection: $model.config.cursorStyle) {
                    Text("Block").tag(Terminal.CursorShape.block)
                    Text("Bar").tag(Terminal.CursorShape.bar)
                    Text("Underline").tag(Terminal.CursorShape.underline)
                }.pickerStyle(.segmented)
                ColorPicker("Color", selection: colorBinding($model.config.cursorColor), supportsOpacity: false)
                Toggle("Blink", isOn: $model.config.cursorBlink)
                Text("Programs can still change the cursor shape (e.g. vim's insert mode) via DECSCUSR.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Motion") {
                Toggle("Cursor trail", isOn: $model.config.cursorTrail)
                Text("A short fading smear when the cursor jumps (not during normal typing).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct EffectsTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section { TerminalPreview(config: model.config) }
            Section("Effect") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(EffectKind.allCases) { kind in
                        Button { model.config.effect = kind } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(kind.title).fontWeight(.semibold)
                                    Spacer()
                                    if model.config.effect == kind { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                                }
                                Text(kind.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(model.config.effect == kind ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.07)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.config.effect == kind ? Color.accentColor : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.config.effect != .none {
                Section("Tuning") {
                    SliderRow(title: "Intensity", value: $model.config.effectIntensity, range: 0.05...1, help: "Opacity of the effect. Keep it low for readability.")
                    SliderRow(title: "Speed", value: $model.config.effectSpeed, range: 0.1...4, format: "%.2f×")
                    if [.matrix, .starfield, .snow, .fireflies].contains(model.config.effect) {
                        SliderRow(title: "Density", value: $model.config.effectDensity, range: 0.05...1, help: "How many columns / particles.")
                    }
                    Toggle("Custom color", isOn: Binding(get: { model.config.effectColor != nil },
                                                         set: { model.config.effectColor = $0 ? model.config.effect.defaultColor : nil }))
                    if model.config.effectColor != nil {
                        ColorPicker("Effect color", selection: colorBinding(Binding(get: { model.config.effectColor ?? model.config.effect.defaultColor },
                                                                                    set: { model.config.effectColor = $0 })), supportsOpacity: false)
                    }
                }
                Section("Performance") {
                    Toggle("Pause when Mantis is in the background", isOn: $model.config.effectPauseWhenInactive)
                    Text("Effects always pause when the window is hidden and when System Settings ▸ Accessibility ▸ Reduce motion is on. They render on their own layer at 30 fps, so terminal text is not redrawn each frame.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct TerminalTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section("Keyboard & mouse") {
                Toggle("Use Option as Meta (Alt) key", isOn: $model.config.optionAsAlt)
                Text("When off, Option types special characters (é, ∑) and ⌥←/⌥→ jump words.").font(.caption).foregroundStyle(.secondary)
                Toggle("Hide mouse pointer while typing", isOn: $model.config.mouseHideWhileTyping)
                Toggle("Copy on select", isOn: $model.config.copyOnSelect)
            }
            Section("Paste") {
                Toggle("Review multi-line pastes before sending", isOn: $model.config.confirmUnsafePaste)
                Text("Shows an editable preview when a paste could run commands immediately.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Scrollback") {
                LabeledContent("Lines kept") {
                    HStack {
                        TextField("", text: intText($model.config.scrollbackLimit)).frame(width: 90).multilineTextAlignment(.trailing)
                        Stepper("", value: $model.config.scrollbackLimit, in: 0...1_000_000, step: 1000).labelsHidden()
                    }
                }
                Text("Applies to new terminals.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Shell") {
                TextField("Command", text: optionalText($model.config.command), prompt: Text("Login shell ($SHELL)"))
                LabeledContent("Working directory") {
                    HStack {
                        TextField("", text: optionalText($model.config.workingDirectory), prompt: Text("Home folder"))
                        Button("Choose…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { model.config.workingDirectory = u.path }
                        }
                    }
                }
                Toggle("Keep window open after the command exits", isOn: $model.config.waitAfterCommand)
                Toggle("Colorize ls and the default prompt", isOn: $model.config.shellColors)
                Text("Shell settings apply to new terminals.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct WindowTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section("New window size") {
                Stepper("Columns: \(model.config.windowWidth)", value: $model.config.windowWidth, in: 20...400)
                Stepper("Rows: \(model.config.windowHeight)", value: $model.config.windowHeight, in: 5...200)
            }
            Section("Splits") {
                SliderRow(title: "Unfocused split opacity", value: $model.config.unfocusedSplitOpacity, range: 0.15...1,
                          help: "Lower values dim inactive panes more. 1.0 disables dimming.")
            }
            Section("Badge") {
                TextField("Badge text", text: optionalText($model.config.badge), prompt: Text("e.g. {host} or PROD"))
                HStack(spacing: 6) {
                    ForEach(["{host}", "{user}", "{cwd}", "{title}"], id: \.self) { tok in
                        Button(tok) { model.config.badge = (model.config.badge ?? "") + tok }.controlSize(.small)
                    }
                }
                Text("A large faded label in the corner of each pane. Override per pane with ⌥⌘B.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct HighlightsTab: View {
    @ObservedObject var model: SettingsModel
    @State private var sample = "[12:00:03] ERROR build FAILED — WARN: retrying in 5s (see Parser.swift:42)"

    var body: some View {
        Form {
            Section("Highlight rules") {
                if model.config.highlightSpecs.isEmpty {
                    Text("No rules yet. Rules recolor matching text in all terminal output.").foregroundStyle(.secondary)
                }
                ForEach($model.config.highlightSpecs) { $spec in
                    HStack {
                        TextField("Regular expression", text: $spec.pattern).font(.system(.body, design: .monospaced))
                        if !spec.isValid {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Invalid regular expression")
                        }
                        ColorPicker("", selection: colorBinding($spec.color), supportsOpacity: false).labelsHidden()
                        Button(role: .destructive) { model.config.highlightSpecs.removeAll { $0.id == spec.id } } label: {
                            Image(systemName: "minus.circle.fill")
                        }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button { model.config.highlightSpecs.append(HighlightSpec(pattern: "TODO", color: RGB(0xE5, 0xC7, 0x6B))) } label: {
                        Label("Add rule", systemImage: "plus")
                    }
                    Spacer()
                    Menu("Presets") {
                        Button("Log levels") {
                            model.config.highlightSpecs += [HighlightSpec(pattern: "ERROR|FATAL|FAIL(ED)?", color: RGB(0xFF, 0x5F, 0x5F)),
                                                            HighlightSpec(pattern: "WARN(ING)?", color: RGB(0xE5, 0xC7, 0x6B)),
                                                            HighlightSpec(pattern: "\\b(OK|PASS(ED)?|SUCCESS)\\b", color: RGB(0x8C, 0xCF, 0x7E))]
                        }
                        Button("IP addresses") { model.config.highlightSpecs.append(HighlightSpec(pattern: "\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b", color: RGB(0x67, 0xB0, 0xE8))) }
                        Button("Timestamps") { model.config.highlightSpecs.append(HighlightSpec(pattern: "\\b\\d{2}:\\d{2}:\\d{2}\\b", color: RGB(0x8A, 0x90, 0xA0))) }
                    }.fixedSize()
                }
            }
            Section("Test") {
                TextField("Sample text", text: $sample).font(.system(.body, design: .monospaced))
                Text(highlighted(sample)).font(.system(.body, design: .monospaced))
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: model.config.background.nsColor)))
            }
            Section("Links & files") {
                TextField("Editor command", text: optionalText($model.config.editor), prompt: Text("Default app (e.g. code -g {file}:{line}:{col})"))
                Text("Used by ⌘-click and hint mode (⇧⌘H) on paths like src/app.swift:42:7. Tokens: {file} {line} {col}.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("VS Code") { model.config.editor = "code -g {file}:{line}:{col}" }
                    Button("Zed") { model.config.editor = "zed {file}:{line}:{col}" }
                    Button("Sublime") { model.config.editor = "subl {file}:{line}:{col}" }
                    Button("Xcode") { model.config.editor = "xed -l {line} {file}" }
                }.controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    private func highlighted(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = Color(nsColor: model.config.foreground.nsColor)
        let ns = s as NSString
        for spec in model.config.highlightSpecs where spec.isValid {
            guard let re = try? NSRegularExpression(pattern: spec.pattern) else { continue }
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                if let r = Range(m.range, in: s), let lo = AttributedString.Index(r.lowerBound, within: a),
                   let hi = AttributedString.Index(r.upperBound, within: a) {
                    a[lo..<hi].foregroundColor = Color(nsColor: spec.color.nsColor)
                }
            }
        }
        return a
    }
}

struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmReset = false
    var body: some View {
        Form {
            Section("Rendering") {
                Picker("Renderer", selection: $model.config.renderer) {
                    ForEach(RendererKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(model.config.renderer == .metal
                     ? "Text is drawn on the GPU from a cached glyph atlas — the fastest option. Falls back to CoreGraphics automatically if Metal is unavailable."
                     : "Text is drawn on the CPU with CoreText. Use this if you notice a rendering problem with Metal.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Configuration file") {
                LabeledContent("Location") { Text(Config.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).textSelection(.enabled) }
                HStack {
                    Button("Reveal in Finder") {
                        if !FileManager.default.fileExists(atPath: Config.path) { model.save() }
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Config.path)])
                    }
                    Button("Open in Editor") {
                        if !FileManager.default.fileExists(atPath: Config.path) { model.save() }
                        NSWorkspace.shared.open(URL(fileURLWithPath: Config.path))
                    }
                    Button("Reload from Disk") { model.reloadFromDisk() }
                }
                Text("Settings writes only values that differ from the defaults. Before the first save, a hand-written file is backed up to config.bak.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview of saved file") {
                ScrollView {
                    Text(model.config.serialized()).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 180)
            }
            Section {
                Button("Reset All Settings to Defaults…", role: .destructive) { confirmReset = true }
                    .confirmationDialog("Reset every setting to its default?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { model.resetToDefaults() }
                    }
            }
        }
        .formStyle(.grouped)
    }
}
