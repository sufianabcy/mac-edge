// EdgePal: counts clicks on a corner (1 to 4) and runs the action set for that count.
import AppKit

final class CornerClicks {
    static let shared = CornerClicks()

    /// How long to wait for another click before running the action.
    var window: TimeInterval = 0.32

    private var corner: Corner?
    private var count = 0
    private var pending: DispatchWorkItem?

    func click(_ tapped: Corner) {
        if corner != tapped { flush() }
        corner = tapped
        count += 1
        pending?.cancel()
        let actions = Settings.shared.actions(for: tapped)
        // No action set for more clicks than this? Then run right away instead of waiting.
        let highest = (actions.lastIndex { $0.isSet } ?? -1) + 1
        if count >= highest {
            flush()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + window, execute: work)
    }

    private func flush() {
        pending?.cancel()
        pending = nil
        defer { corner = nil; count = 0 }
        guard let corner, count > 0 else { return }
        let actions = Settings.shared.actions(for: corner)
        guard count <= actions.count else { return }
        let action = actions[count - 1]
        EdgeEngine.shared.report("\(corner.title), \(count)× → \(action.kind.title)")
        CornerActions.run(action)
    }
}

enum CornerActions {
    static func run(_ action: CornerAction) {
        switch action.kind {
        case .none:
            break
        case .mute:
            SystemControls.press(.mute)
        case .playPause:
            SystemControls.press(.playPause)
        case .openApp:
            toggleApp(at: action.appPath)
        case .openLink:
            open(action.link, browser: action.browserPath)
        case .keyCombo:
            SystemControls.pressCombo(keyCode: action.keyCode, modifiers: action.modifiers)
        case .shortcut:
            runShortcut(action.shortcutName)
        }
    }

    /// Opens the app, or hides it when it's already in front.
    static func toggleApp(at path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if let id = Bundle(url: url)?.bundleIdentifier,
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
           running.isActive {
            running.hide()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    static func open(_ text: String, browser: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url: URL?
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        } else if trimmed.contains("://") || trimmed.hasPrefix("mailto:") {
            url = URL(string: trimmed)
        } else {
            url = URL(string: "https://" + trimmed)
        }
        guard let url else { return }
        if !browser.isEmpty, url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: browser),
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func runShortcut(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", trimmed]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// The names of the user's Shortcuts, for the picker in Settings.
    static func shortcutNames() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["list"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }.sorted()
    }
}
