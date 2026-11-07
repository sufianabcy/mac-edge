// EdgePal: the Settings window.
import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }
            EdgesPane().tabItem { Label("Edges", systemImage: "rectangle.dashed") }
            CornersPane().tabItem { Label("Corners", systemImage: "square.grid.2x2") }
            AppsPane().tabItem { Label("Apps", systemImage: "app.badge") }
        }
        .frame(width: 560, height: 560)
    }
}

// MARK: General

/// Polls the Accessibility permission so the UI updates once the user grants it.
final class PermissionModel: ObservableObject {
    @Published var trusted = AXIsProcessTrusted()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let now = AXIsProcessTrusted()
            if now != self?.trusted { self?.trusted = now }
            if now { EdgeEngine.shared.startTap() }
        }
    }

    deinit { timer?.invalidate() }

    func ask() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openSettings()
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct PermissionRow: View {
    @StateObject private var permission = PermissionModel()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: permission.trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(permission.trusted ? .green : .orange)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.trusted ? "Accessibility is on" : "Accessibility is needed")
                    .font(.headline)
                Text("EdgePal uses it to press the volume and brightness keys for you and to keep edge clicks out of your apps. It never records what you type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !permission.trusted {
                Button("Allow…") { permission.ask() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct GeneralPane: View {
    @ObservedObject private var settings = Settings.shared
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("EdgePal is on", isOn: $settings.enabled)
                PermissionRow()
            }
            Section("Feel") {
                Toggle("Haptic tick on every step", isOn: $settings.haptics)
                Picker("Strength", selection: $settings.hapticStrength) {
                    Text("Light").tag(1)
                    Text("Medium").tag(2)
                    Text("Strong").tag(3)
                }
                .pickerStyle(.segmented)
                .disabled(!settings.haptics)
            }
            Section("Startup") {
                Toggle("Open EdgePal when you log in", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Button("Show the welcome guide again") {
                    AppDelegate.shared?.showWelcome()
                }
            }
            Section {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                Text("EdgePal \(version). Every touch is handled on this Mac; nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Edges

private struct EdgesPane: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var engine = EdgeEngine.shared

    var body: some View {
        Form {
            Section {
                TrackpadPreview()
                    .frame(height: 150)
                Text(engine.lastAction)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("Press an edge until the trackpad clicks, then slide. The middle works as always.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Edges") {
                Toggle("Volume (\(settings.swapSides ? "left" : "right") edge)", isOn: $settings.volumeEdge)
                Toggle("Brightness (\(settings.swapSides ? "right" : "left") edge)", isOn: $settings.brightnessEdge)
                Toggle("Video and music timeline (bottom edge)", isOn: $settings.timelineEdge)
                Toggle("Swap volume and brightness", isOn: $settings.swapSides)
                if settings.brightnessDirect {
                    Text("This Mac ignores brightness keys pressed by apps, so EdgePal sets the brightness directly. You won't see the brightness indicator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Size and speed") {
                LabeledContent("Edge width") {
                    HStack {
                        Slider(value: $settings.edgeWidth, in: 0.05 ... 0.20, step: 0.01)
                        Text("\(Int((settings.edgeWidth * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("Slide per step") {
                    HStack {
                        Slider(value: $settings.stepMM, in: 2 ... 8, step: 0.5)
                        Text(String(format: "%.1f mm", settings.stepMM))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Text("Hold ⇧ Shift and ⌥ Option while sliding for quarter steps and finer scrubbing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Safety") {
                Picker("To start a gesture", selection: $settings.modifier) {
                    ForEach(ModifierRequirement.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Corners

private struct CornersPane: View {
    @ObservedObject private var settings = Settings.shared
    @State private var shortcutNames: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle("Use the top corners", isOn: $settings.cornersEnabled)
            } footer: {
                Text("Click a top corner 1 to 4 times. A corner with nothing set stays a normal part of the trackpad.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Corner.allCases) { corner in
                Section(corner.title) {
                    ForEach(1 ... 4, id: \.self) { clicks in
                        CornerActionEditor(
                            clicks: clicks,
                            shortcutNames: shortcutNames,
                            action: Binding(
                                get: { settings.actions(for: corner)[clicks - 1] },
                                set: { settings.setAction($0, corner: corner, clicks: clicks) }))
                    }
                }
                .disabled(!settings.cornersEnabled)
            }
        }
        .formStyle(.grouped)
        .task {
            let names = await Task.detached { CornerActions.shortcutNames() }.value
            shortcutNames = names
        }
    }
}

private struct CornerActionEditor: View {
    let clicks: Int
    let shortcutNames: [String]
    @Binding var action: CornerAction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(clicks == 1 ? "1 click" : "\(clicks) clicks", selection: $action.kind) {
                ForEach(CornerActionKind.allCases) { Text($0.title).tag($0) }
            }
            switch action.kind {
            case .openApp:
                HStack {
                    Text(action.appPath.isEmpty ? "No app chosen" : FileManager.default.displayName(atPath: action.appPath))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose App…") {
                        if let url = choose(apps: true) { action.appPath = url.path }
                    }
                }
                Text("Click again while it's in front to hide it.").font(.caption).foregroundStyle(.secondary)
            case .openLink:
                TextField("Website, file or folder", text: $action.link, prompt: Text("claude.ai or ~/Documents"))
                HStack {
                    Text(action.browserPath.isEmpty ? "Opens in your default browser"
                         : "Opens in " + FileManager.default.displayName(atPath: action.browserPath))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Browser…") {
                        if let url = choose(apps: true) { action.browserPath = url.path }
                    }
                    if !action.browserPath.isEmpty {
                        Button("Default") { action.browserPath = "" }
                    }
                }
            case .keyCombo:
                KeyRecorder(action: $action)
            case .shortcut:
                if shortcutNames.isEmpty {
                    TextField("Shortcut name", text: $action.shortcutName)
                } else {
                    Picker("Shortcut", selection: $action.shortcutName) {
                        Text("Choose…").tag("")
                        ForEach(shortcutNames, id: \.self) { Text($0).tag($0) }
                    }
                }
            default:
                EmptyView()
            }
        }
    }

    private func choose(apps: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Click, then press the key combination to save it.
private struct KeyRecorder: View {
    @Binding var action: CornerAction
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(recording ? "Press the keys now…" : (action.keyLabel.isEmpty ? "No keys set" : action.keyLabel))
                .font(.body.monospaced())
                .foregroundStyle(recording ? Color.accentColor : .secondary)
            Spacer()
            Button(recording ? "Cancel" : "Record Keys") { recording ? stop() : start() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop() // Esc on its own cancels.
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control, .function])
            var flags: CGEventFlags = []
            if mods.contains(.command) { flags.insert(.maskCommand) }
            if mods.contains(.shift) { flags.insert(.maskShift) }
            if mods.contains(.option) { flags.insert(.maskAlternate) }
            if mods.contains(.control) { flags.insert(.maskControl) }
            action.keyCode = Int(event.keyCode)
            action.modifiers = flags.rawValue
            action.keyLabel = KeyRecorder.label(mods: mods, event: event)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func label(mods: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var text = ""
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        let special: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
            101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[event.keyCode] {
            return text + name
        }
        return text + (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

// MARK: Apps

private struct AppsPane: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                if settings.pausedApps.isEmpty {
                    Text("EdgePal works in every app.")
                        .foregroundStyle(.secondary)
                }
                ForEach(settings.pausedApps, id: \.self) { id in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable().frame(width: 20, height: 20)
                            Text(FileManager.default.displayName(atPath: url.path))
                        } else {
                            Text(id)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.pausedApps.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { addApp() }
            } header: {
                Text("Step aside in these apps")
            } footer: {
                Text("While one of these apps is in front, edge clicks are normal clicks. Handy for drawing apps and games.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !settings.pausedApps.contains(id) {
                settings.pausedApps.append(id)
            }
        }
    }
}
