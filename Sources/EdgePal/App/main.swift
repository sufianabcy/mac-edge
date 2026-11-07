// EdgePal: the edges of your Mac trackpad, put to work.
import AppKit

if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar only, no Dock icon.
app.run()
