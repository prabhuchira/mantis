import AppKit
import Carbon // EnableSecureEventInput
import UserNotifications
import MantisCore

/// macOS app runtime: Swift owns windows, the core owns terminals.

enum Notifier {
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { // UNUserNotificationCenter needs an .app bundle
            NSApp.requestUserAttention(.informationalRequest); return
        }
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent(); n.title = title; n.body = body
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: n, trigger: nil))
        }
    }
}

/// One window = a tree of split panes, each a TerminalView. Tabs are native
/// NSWindow tabs.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private(set) var config: Config
    private(set) var panes: [TerminalView] = []
    private weak var focused: TerminalView?

    init(config: Config) {
        self.config = config
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.tabbingMode = .preferred
        w.tabbingIdentifier = "mantis"
        w.title = "Mantis"
        w.isRestorable = false
        super.init(window: w)
        w.delegate = self

        let tv = makePane()
        w.contentView = tv
        w.setContentSize(tv.preferredContentSize)
        applyWindowAppearance()
        w.center()
        w.makeFirstResponder(tv)
        tv.start()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyWindowAppearance() {
        guard let w = window else { return }
        w.backgroundColor = config.background.nsColor.withAlphaComponent(config.backgroundOpacity)
        w.isOpaque = config.backgroundOpacity >= 1
    }

    /// Live-apply new settings to the window and every pane in it.
    func applyConfig(_ c: Config) {
        config = c
        applyWindowAppearance()
        panes.forEach { $0.applyConfig(c) }
    }

    private func makePane() -> TerminalView {
        let tv = TerminalView(config: config)
        tv.onTitle = { [weak self, weak tv] t in
            guard let self, let tv, tv === self.focused || self.panes.count == 1 else { return }
            self.window?.title = t.isEmpty ? "Mantis" : t
        }
        tv.onCwd = { [weak self] d in self?.window?.representedURL = URL(fileURLWithPath: d) }
        tv.onClose = { [weak self] v in self?.closePane(v) }
        tv.onFocus = { [weak self] v in
            self?.focused = v
            if let t = v.terminal.title as String?, !t.isEmpty { self?.window?.title = t }
        }
        panes.append(tv)
        focused = tv
        return tv
    }

    // MARK: Splits

    @objc func splitRight(_ sender: Any?) { split(vertical: true) }
    @objc func splitDown(_ sender: Any?) { split(vertical: false) }

    private func split(vertical: Bool) {
        guard let target = focused, let parent = target.superview ?? window?.contentView else { return }
        let sv = NSSplitView()
        sv.isVertical = vertical
        sv.dividerStyle = .thin
        sv.autoresizingMask = [.width, .height]
        let newPane = makePane()

        if window?.contentView === target {
            window?.contentView = sv
        } else if let parentSplit = parent as? NSSplitView, let idx = parentSplit.arrangedSubviews.firstIndex(of: target) {
            parentSplit.removeArrangedSubview(target)
            target.removeFromSuperview()
            parentSplit.insertArrangedSubview(sv, at: idx)
        }
        sv.frame = target.frame
        sv.addArrangedSubview(target)
        sv.addArrangedSubview(newPane)
        sv.adjustSubviews()
        let half = (vertical ? sv.bounds.width : sv.bounds.height) / 2
        sv.setPosition(half, ofDividerAt: 0)
        window?.makeFirstResponder(newPane)
        newPane.start()
    }

    func closePane(_ v: TerminalView) {
        v.shutdown()
        panes.removeAll { $0 === v }
        if panes.isEmpty { window?.close(); return }
        guard let split = v.superview as? NSSplitView else { return }
        v.removeFromSuperview()
        // Collapse a split that now has a single child.
        if split.arrangedSubviews.count == 1, let only = split.arrangedSubviews.first {
            split.removeArrangedSubview(only); only.removeFromSuperview()
            if window?.contentView === split {
                window?.contentView = only
            } else if let gp = split.superview as? NSSplitView, let idx = gp.arrangedSubviews.firstIndex(of: split) {
                gp.removeArrangedSubview(split); split.removeFromSuperview()
                gp.insertArrangedSubview(only, at: idx)
            }
        }
        if let next = panes.last { window?.makeFirstResponder(next) }
    }

    @objc func closePaneAction(_ sender: Any?) {
        guard let f = focused else { return }
        confirmIfBusy([f]) { [weak self] in self?.closePane(f) }
    }

    @objc func focusNextPane(_ sender: Any?) { cycleFocus(1) }
    @objc func focusPreviousPane(_ sender: Any?) { cycleFocus(-1) }
    private func cycleFocus(_ d: Int) {
        guard let f = focused, let i = panes.firstIndex(where: { $0 === f }), panes.count > 1 else { return }
        window?.makeFirstResponder(panes[(i + d + panes.count) % panes.count])
    }

    @objc func equalizeSplits(_ sender: Any?) {
        func eq(_ v: NSView) {
            guard let s = v as? NSSplitView else { return }
            let n = s.arrangedSubviews.count
            let total = s.isVertical ? s.bounds.width : s.bounds.height
            for i in 0..<(n - 1) { s.setPosition(total * CGFloat(i + 1) / CGFloat(n), ofDividerAt: i) }
            s.arrangedSubviews.forEach(eq)
        }
        if let c = window?.contentView { eq(c) }
    }

    // MARK: Close confirmation

    private func confirmIfBusy(_ views: [TerminalView], then: @escaping () -> Void) {
        guard views.contains(where: { $0.pty.hasForegroundJob }), let w = window else { then(); return }
        let a = NSAlert()
        a.messageText = "Close terminal?"
        a.informativeText = "A process is still running. Closing will terminate it."
        a.addButton(withTitle: "Close"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { then() } }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if panes.contains(where: { $0.pty.hasForegroundJob }) {
            confirmIfBusy(panes) { [weak self] in
                self?.panes.forEach { $0.shutdown() }; self?.panes.removeAll(); sender.close()
            }
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        panes.forEach { $0.shutdown() }
        panes.removeAll()
        AppDelegate.shared.controllers.removeAll { $0 === self }
    }

    @objc override func newWindowForTab(_ sender: Any?) { AppDelegate.shared.newTab(sender) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    static var shared: AppDelegate!
    var config = Config.load()
    lazy var settings: SettingsModel = {
        let m = SettingsModel()
        m.onApply = { [weak self] c in self?.applyLive(c) }
        return m
    }()
    private var settingsWindow: SettingsWindowController?

    /// Settings are authoritative once edited: update new-window config and every open pane.
    func applyLive(_ c: Config) {
        config = c
        controllers.forEach { $0.applyConfig(c) }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: settings) }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettingsEffects(_ sender: Any?) { settings.tab = 2; showSettings(sender) }

    @objc func selectEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = EffectKind(rawValue: raw) else { return }
        settings.config.effect = kind // applies live + saves
    }
    var controllers: [TerminalWindowController] = []
    private(set) var secureInput = false

    // MARK: 7. Secure Keyboard Entry — blocks other processes from observing keystrokes.
    // Like Terminal.app, it is only held while Mantis is the active app.
    @objc func toggleSecureInput(_ sender: Any?) {
        secureInput.toggle()
        if NSApp.isActive {
            if secureInput { EnableSecureEventInput() } else { DisableSecureEventInput() }
        }
        updateSecureSubtitle()
    }

    func applicationDidBecomeActive(_ n: Notification) { if secureInput { EnableSecureEventInput() } }
    func applicationDidResignActive(_ n: Notification) { if secureInput { DisableSecureEventInput() } }
    func applicationWillTerminate(_ n: Notification) { if secureInput { DisableSecureEventInput() } }

    func updateSecureSubtitle() {
        for c in controllers { c.window?.subtitle = secureInput ? "🔒 Secure Keyboard Entry" : "" }
    }

    // "Go to Highlight" is rebuilt from the focused pane each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Go to Highlight" else { return }
        menu.removeAllItems()
        let items = (NSApp.keyWindow?.firstResponder as? TerminalView)?.highlightMenuItems() ?? []
        if items.isEmpty {
            menu.addItem(NSMenuItem(title: "No highlights — select text and press ⌘L", action: nil, keyEquivalent: ""))
        } else { items.forEach(menu.addItem) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSecureInput(_:)) { item.state = secureInput ? .on : .off }
        if item.action == #selector(selectEffect(_:)) {
            item.state = (item.representedObject as? String) == config.effect.rawValue ? .on : .off
        }
        return true
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let c = newWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !config.errors.isEmpty { showConfigErrors() }

        // Headless verification: MANTIS_SNAPSHOT=/path.png renders the first window to PNG and exits.
        if let path = ProcessInfo.processInfo.environment["MANTIS_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["MANTIS_SNAPSHOT_DELAY"] ?? "") ?? 2.0
            if let tab = ProcessInfo.processInfo.environment["MANTIS_SNAPSHOT_SETTINGS"].flatMap(Int.init) {
                settings.tab = tab; showSettings(nil)
            }
            if ProcessInfo.processInfo.environment["MANTIS_SNAPSHOT_SPLITS"] != nil {
                c.splitRight(nil); c.splitDown(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // MANTIS_SNAPSHOT_SETTINGS=<tab index> captures the Settings window instead
                if let tab = ProcessInfo.processInfo.environment["MANTIS_SNAPSHOT_SETTINGS"].flatMap(Int.init),
                   let sw = self.settingsWindow?.window?.contentView {
                    _ = tab
                    sw.display()
                    let ok = Self.writePNG(of: sw, to: path)
                    FileHandle.standardError.write("settings snapshot \(ok ? "written" : "FAILED"): \(path)\n".data(using: .utf8)!)
                    NSApp.terminate(nil); return
                }
                // e.g. MANTIS_SNAPSHOT_ACTIONS=toggleBookmark:,enterHintMode:  (selectors run on the first pane)
                if let acts = ProcessInfo.processInfo.environment["MANTIS_SNAPSHOT_ACTIONS"], let tv = c.panes.first {
                    for a in acts.split(separator: ",") { tv.perform(NSSelectorFromString(String(a)), with: nil) }
                }
                if let root = c.window?.contentView {
                    root.display()
                    let ok = Self.writePNG(of: root, to: path)
                    FileHandle.standardError.write("snapshot \(ok ? "written" : "FAILED"): \(path)\n".data(using: .utf8)!)
                }
                NSApp.terminate(nil)
            }
        }
    }

    static func writePNG(of v: NSView, to path: String) -> Bool {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    @discardableResult
    @objc func newWindow(_ sender: Any?) -> TerminalWindowController {
        let c = TerminalWindowController(config: config)
        controllers.append(c)
        if let last = controllers.dropLast().last?.window {
            c.window?.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        c.showWindow(nil)
        updateSecureSubtitle()
        return c
    }

    @objc func newTab(_ sender: Any?) {
        guard let key = NSApp.keyWindow else { newWindow(sender); return }
        let c = TerminalWindowController(config: config)
        controllers.append(c)
        key.addTabbedWindow(c.window!, ordered: .above)
        updateSecureSubtitle()
        c.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openConfig(_ sender: Any?) {
        let path = Config.path
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? Config.sampleFile.write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func reloadConfig(_ sender: Any?) {
        settings.reloadFromDisk() // re-reads the file and live-applies it to every terminal
        if !settings.config.errors.isEmpty { config = settings.config; showConfigErrors() }
    }

    private func showConfigErrors() {
        let a = NSAlert()
        a.messageText = "Configuration errors"
        a.informativeText = config.errors.joined(separator: "\n")
        a.runModal()
    }

    private func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let it = NSMenuItem(); let m = NSMenu(title: title); items.forEach(m.addItem); it.submenu = m; main.addItem(it)
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; return i
        }
        sub("Mantis", [
            item("About Mantis", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ","),
            item("Open Config File…", #selector(openConfig(_:)), ",", [.command, .option]),
            item("Reload Configuration", #selector(reloadConfig(_:)), ",", [.command, .shift]),
            .separator(),
            item("Secure Keyboard Entry", #selector(toggleSecureInput(_:)), ""),
            .separator(),
            item("Hide Mantis", #selector(NSApplication.hide(_:)), "h"),
            item("Quit Mantis", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("Shell", [
            item("New Window", #selector(newWindow(_:)), "n"),
            item("New Tab", #selector(newTab(_:)), "t"),
            .separator(),
            item("Split Right", #selector(TerminalWindowController.splitRight(_:)), "d"),
            item("Split Down", #selector(TerminalWindowController.splitDown(_:)), "d", [.command, .shift]),
            item("Next Split", #selector(TerminalWindowController.focusNextPane(_:)), "]"),
            item("Previous Split", #selector(TerminalWindowController.focusPreviousPane(_:)), "["),
            item("Equalize Splits", #selector(TerminalWindowController.equalizeSplits(_:)), "=", [.command, .control]),
            .separator(),
            item("Close", #selector(TerminalWindowController.closePaneAction(_:)), "w"),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
        ])
        sub("Edit", [
            item("Copy", #selector(TerminalView.copy(_:)), "c"),
            item("Paste", #selector(TerminalView.paste(_:)), "v"),
            item("Select All", #selector(TerminalView.selectAll(_:)), "a"),
            .separator(),
            item("Copy as HTML", #selector(TerminalView.copyAsHTML(_:)), "c", [.command, .option]),
            .separator(),
            item("Find…", #selector(TerminalView.showFind(_:)), "f"),
            item("Find Next", #selector(TerminalView.findNext(_:)), "g"),
            item("Find Previous", #selector(TerminalView.findPrevious(_:)), "g", [.command, .shift]),
            .separator(),
            item("Clear Screen", #selector(TerminalView.clearBuffer(_:)), "k"),
        ])
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        sub("Navigate", [
            item("Hints (open / ⇧copy)", #selector(TerminalView.enterHintMode(_:)), "h", [.command, .shift]),
            .separator(),
            item("Toggle Bookmark", #selector(TerminalView.toggleBookmark(_:)), "b"),
            item("Previous Bookmark", #selector(TerminalView.previousBookmark(_:)), up),
            item("Next Bookmark", #selector(TerminalView.nextBookmark(_:)), down),
            item("Clear Bookmarks", #selector(TerminalView.clearBookmarks(_:)), ""),
            .separator(),
            item("Highlight Selection", #selector(TerminalView.highlightSelection(_:)), "l"),
            { () -> NSMenuItem in
                let it = NSMenuItem(title: "Highlight With", action: nil, keyEquivalent: "")
                let m = NSMenu(title: "Highlight With")
                for (i, name) in Marker.names.enumerated() {
                    let c = item(name, #selector(TerminalView.highlightWithColor(_:)), "\(i + 1)", [.command, .option])
                    c.tag = i; c.image = Marker.swatch(i); m.addItem(c)
                }
                it.submenu = m
                return it
            }(),
            item("Remove Highlight", #selector(TerminalView.removeHighlightAction(_:)), "l", [.command, .option]),
            item("Next Highlight", #selector(TerminalView.nextHighlight(_:)), down, [.command, .control]),
            item("Previous Highlight", #selector(TerminalView.previousHighlight(_:)), up, [.command, .control]),
            { () -> NSMenuItem in
                let it = NSMenuItem(title: "Go to Highlight", action: nil, keyEquivalent: "")
                let m = NSMenu(title: "Go to Highlight")
                m.delegate = self // filled from the focused pane when opened
                it.submenu = m
                return it
            }(),
            item("Copy All Highlights (Markdown)", #selector(TerminalView.copyAllHighlights(_:)), "l", [.command, .shift]),
            item("Clear All Highlights", #selector(TerminalView.clearAllHighlights(_:)), ""),
        ])
        sub("View", [
            item("Increase Font Size", #selector(TerminalView.increaseFontSize(_:)), "="),
            item("Decrease Font Size", #selector(TerminalView.decreaseFontSize(_:)), "-"),
            item("Reset Font Size", #selector(TerminalView.resetFontSize(_:)), "0"),
            .separator(),
            item("Set Badge…", #selector(TerminalView.setBadge(_:)), "b", [.command, .option]),
            { () -> NSMenuItem in
                let it = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
                let m = NSMenu(title: "Effect")
                for k in EffectKind.allCases {
                    let e = NSMenuItem(title: k.title, action: #selector(AppDelegate.selectEffect(_:)), keyEquivalent: "")
                    e.representedObject = k.rawValue
                    m.addItem(e)
                    if k == .none { m.addItem(.separator()) }
                }
                m.addItem(.separator())
                m.addItem(item("Effect Settings…", #selector(AppDelegate.showSettingsEffects(_:)), ""))
                it.submenu = m
                return it
            }(),
            .separator(),
            item("Scroll to Top", #selector(TerminalView.scrollToTop(_:)), String(UnicodeScalar(NSHomeFunctionKey)!)),
            item("Scroll to Bottom", #selector(TerminalView.scrollToBottomAction(_:)), String(UnicodeScalar(NSEndFunctionKey)!)),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let win = NSMenu(title: "Window")
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        win.addItem(item("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", [.command, .shift]))
        win.addItem(item("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", [.command, .shift]))
        let winItem = NSMenuItem(); winItem.submenu = win; main.addItem(winItem)
        NSApp.windowsMenu = win
        NSApp.mainMenu = main
    }
}

extension Config {
    static let sampleFile = """
    # Mantis configuration — syntax: `key = value`
    # font-family = JetBrains Mono
    # font-size = 14
    # background = 14161b
    # foreground = d6dae3
    # cursor-color = f2c14e
    # cursor-style = block        # block | bar | underline
    # cursor-style-blink = true
    # background-opacity = 0.95
    # window-padding-x = 8
    # window-padding-y = 6
    # window-width = 100          # columns
    # window-height = 30          # rows
    # scrollback-limit = 10000
    # macos-option-as-alt = false
    # copy-on-select = false
    # clipboard-paste-protection = true
    # minimum-contrast = 1.1
    # palette = 1=#ff5555
    # command = /opt/homebrew/bin/fish
    #
    # --- extras ---
    # highlight = ERROR|FAIL(ED)?=#ff5f5f      (repeatable: REGEX=#color)
    # highlight = WARN(ING)?=#e5c76b
    # editor = code -g {file}:{line}:{col}      (⌘-click / hints on file:line)
    # badge = {host}                            (tokens: {host} {user} {cwd} {title})
    # unfocused-split-opacity = 0.7
    # cursor-trail = true
    """
}
