import AppKit
import Carbon // EnableSecureEventInput
import UserNotifications
import MantisCore

/// macOS app runtime (Ghostty: macos/Sources/App + Features/Terminal, i.e. the
/// "embedded" apprt where Swift owns windows and the core owns terminals).

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
/// NSWindow tabs (Ghostty also uses native macOS tabs).
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    let config: Config
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
        w.backgroundColor = config.background.nsColor.withAlphaComponent(config.backgroundOpacity)
        if config.backgroundOpacity < 1 { w.isOpaque = false }
        w.center()
        w.makeFirstResponder(tv)
        tv.start()
    }

    required init?(coder: NSCoder) { fatalError() }

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

    // MARK: Splits (Ghostty: SplitTree / split_right, split_down)

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

    // MARK: Close confirmation (Ghostty: confirm-close-surface)

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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate!
    var config = Config.load()
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSecureInput(_:)) { item.state = secureInput ? .on : .off }
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
            if ProcessInfo.processInfo.environment["MANTIS_SNAPSHOT_SPLITS"] != nil {
                c.splitRight(nil); c.splitDown(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
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
        config = Config.load()
        if !config.errors.isEmpty { showConfigErrors() }
        // New surfaces pick up the new config (live-reload of existing ones is on the roadmap).
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
            item("Settings…", #selector(openConfig(_:)), ","),
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
        ])
        sub("View", [
            item("Increase Font Size", #selector(TerminalView.increaseFontSize(_:)), "="),
            item("Decrease Font Size", #selector(TerminalView.decreaseFontSize(_:)), "-"),
            item("Reset Font Size", #selector(TerminalView.resetFontSize(_:)), "0"),
            .separator(),
            item("Set Badge…", #selector(TerminalView.setBadge(_:)), "b", [.command, .option]),
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
    # Mantis configuration — syntax mirrors Ghostty: `key = value`
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
