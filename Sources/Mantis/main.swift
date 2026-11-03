import AppKit

signal(SIGPIPE, SIG_IGN) // a closed pty must not kill the GUI

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
AppDelegate.shared = delegate
app.delegate = delegate
app.run()
