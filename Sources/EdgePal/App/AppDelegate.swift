// EdgePal: app startup, the menu bar icon and the windows.
import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setUpMenuBar()
        EdgeEngine.shared.start()
        if !Settings.shared.finishedWelcome || !AXIsProcessTrusted() {
            showWelcome()
        }
        // Start the event tap as soon as the user grants Accessibility.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            if EdgeEngine.shared.startTap() {
                self?.updateIcon()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        EdgeEngine.shared.releasePointer()
        EdgeEngine.shared.stopTap()
        TouchMonitor.shared.stop()
        MediaHelper.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    // MARK: Menu bar

    private func setUpMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateIcon()
    }

    private func updateIcon() {
        let on = Settings.shared.enabled && EdgeEngine.shared.tapRunning
        let image = NSImage(systemSymbolName: on ? "rectangle.and.hand.point.up.left.fill" : "rectangle.and.hand.point.up.left",
                            accessibilityDescription: "EdgePal")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.appearsDisabled = !on
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = Settings.shared
        let engine = EdgeEngine.shared

        if !engine.tapRunning {
            let warn = NSMenuItem(title: "Allow Accessibility to start…", action: #selector(openWelcome), keyEquivalent: "")
            warn.target = self
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Edge Gestures", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = settings.enabled ? .on : .off
        menu.addItem(toggle)

        if let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
           id != Bundle.main.bundleIdentifier {
            let paused = settings.pausedApps.contains(id)
            let item = NSMenuItem(title: paused ? "Use in \(app.localizedName ?? id)" : "Pause in \(app.localizedName ?? id)",
                                  action: #selector(togglePausedApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }

        if let now = MediaHelper.shared.current {
            menu.addItem(.separator())
            let info = NSMenuItem(title: "Bottom edge: \(now.title.isEmpty ? "Now Playing" : now.title)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }

        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let guide = NSMenuItem(title: "Welcome Guide…", action: #selector(openWelcome), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit EdgePal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled.toggle()
        updateIcon()
    }

    @objc private func togglePausedApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let settings = Settings.shared
        if settings.pausedApps.contains(id) {
            settings.pausedApps.removeAll { $0 == id }
        } else {
            settings.pausedApps.append(id)
        }
    }

    @objc private func openSettings() { showSettings() }
    @objc private func openWelcome() { showWelcome() }

    // MARK: Windows

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "EdgePal Settings", view: SettingsView())
        }
        present(settingsWindow)
    }

    func showWelcome() {
        if welcomeWindow == nil {
            welcomeWindow = makeWindow(title: "Welcome to EdgePal", view: WelcomeView { [weak self] in
                self?.welcomeWindow?.close()
            })
        }
        present(welcomeWindow)
    }

    private func makeWindow<V: View>(title: String, view: V) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
