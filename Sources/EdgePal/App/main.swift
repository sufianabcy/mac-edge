// EdgePal: the edges of your Mac trackpad, put to work.
import AppKit

// Writing to the media helper just after it died must fail quietly, not end EdgePal: by
// default a write to a closed pipe kills the writer with SIGPIPE, and leaves no crash report.
signal(SIGPIPE, SIG_IGN)

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}
if let flag = CommandLine.arguments.firstIndex(of: "--hud-snapshot"), flag + 1 < CommandLine.arguments.count {
    let saved = MainActor.assumeIsolated { ScrubHUD.snapshot(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1])) }
    exit(saved ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar only, no Dock icon.
app.run()
