// EdgePal: `EdgePal --selftest` checks every piece that doesn't need a finger or a permission.
import AppKit
import ApplicationServices
import EdgeTouch

enum SelfTest {
    static func run() {
        func line(_ ok: Bool, _ text: String) { print((ok ? "✓ " : "✗ ") + text) }

        line(ETLoad(), "MultitouchSupport loaded")
        var frames = 0
        let lock = NSLock()
        var size = ""
        TouchMonitor.shared.frameHandler = { frame in
            lock.lock()
            frames += 1
            size = String(format: "%.0f × %.0f mm", frame.widthMM, frame.heightMM)
            lock.unlock()
        }
        let devices = TouchMonitor.shared.start()
        line(devices > 0, "\(devices) trackpad(s) started")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        lock.lock(); let seen = frames; lock.unlock()
        print("  frames in 1.5 s: \(seen) (0 is normal if nothing touched the trackpad)")
        if !size.isEmpty { print("  trackpad surface: \(size)") }

        let layout = ZoneLayout(width: 160, height: 100, edgeShare: 0.10)
        let zonesOK = layout.zones(x: 5, y: 50) == [.left]
            && layout.zones(x: 155, y: 50) == [.right]
            && layout.zones(x: 80, y: 5) == [.bottom]
            && layout.zones(x: 5, y: 95) == [.topLeft, .left]
            && layout.zones(x: 155, y: 5) == [.bottom, .right]
            && layout.zones(x: 80, y: 50).isEmpty
        line(zonesOK, "zone layout")

        line(AXIsProcessTrusted(), "Accessibility permission (needed for gestures)")
        let display = SystemControls.builtInDisplay
        line(display != nil, "built-in display (needed for the brightness edge)")
        if let b = Brightness.get() { print("  brightness now: \(Int(b * 100))%") }

        if MediaHelper.resources() == nil {
            line(false, "media helper files (set EDGEPAL_RESOURCES or run from the .app)")
        } else {
            MediaHelper.shared.start()
            MediaHelper.shared.refresh()
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            line(MediaHelper.shared.isRunning, "media helper running")
            if let now = MediaHelper.shared.current {
                print("  now playing: \(now.title) — \(formatTime(now.position())) / \(formatTime(now.duration))")
            } else {
                print("  now playing: nothing (bottom edge stays a normal click)")
            }
            MediaHelper.shared.stop()
        }
        TouchMonitor.shared.stop()
    }
}
