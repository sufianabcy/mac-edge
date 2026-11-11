// EdgePal: `EdgePal --selftest` checks every piece that doesn't need a finger or a permission.
// Exits with 1 if a check fails (lines marked ✗). Lines marked · describe this Mac, not a fault.
import AppKit
import ApplicationServices
import EdgeTouch

enum SelfTest {
    private static var failures = 0

    private static func check(_ ok: Bool, _ text: String) {
        print((ok ? "✓ " : "✗ ") + text)
        if !ok { failures += 1 }
    }

    private static func status(_ ok: Bool, _ text: String) {
        print((ok ? "✓ " : "· ") + text)
    }

    static func run() -> Int32 {
        check(ETLoad(), "MultitouchSupport loaded")
        var frames = 0
        let lock = NSLock()
        var size = ""
        var width = 0.0
        TouchMonitor.shared.frameHandler = { frame in
            lock.lock()
            frames += 1
            size = String(format: "%.0f × %.0f mm", frame.widthMM, frame.heightMM)
            width = frame.widthMM
            lock.unlock()
        }
        let devices = TouchMonitor.shared.start()
        check(devices > 0, "\(devices) trackpad(s) started")
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        lock.lock(); let seen = frames; let trackpad = size; let trackpadWidth = width; lock.unlock()
        print("  frames in 1.5 s: \(seen) (0 is normal if nothing touched the trackpad)")
        if !trackpad.isEmpty { print("  trackpad surface: \(trackpad)") }

        let layout = ZoneLayout(width: 160, height: 100, edgeShare: 0.10)
        let zonesOK = layout.zones(x: 5, y: 50) == [.left]
            && layout.zones(x: 155, y: 50) == [.right]
            && layout.zones(x: 80, y: 5) == [.bottom]
            && layout.zones(x: 5, y: 95) == [.topLeft, .left]
            && layout.zones(x: 155, y: 5) == [.bottom, .right]
            && layout.zones(x: 80, y: 50).isEmpty
        check(zonesOK, "zone layout")

        status(AXIsProcessTrusted(), "Accessibility permission (needed for gestures)")
        let display = SystemControls.builtInDisplay
        status(display != nil, "built-in display (needed for the brightness edge)")
        if let b = Brightness.get() { print("  brightness now: \(Int(b * 100))%") }

        print("Bottom edge")
        scrubChecks(width: trackpadWidth > 40 ? trackpadWidth : 130)
        mediaChecks()

        TouchMonitor.shared.stop()
        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0 ? 0 : 1
    }

    // MARK: Scrubbing

    /// Slides a simulated finger at 120 frames a second: each step moves `dx` mm in `seconds`.
    private static func slide(duration: Double, start: Double, width: Double, drift: Double = 0,
                              fine: Bool = false, _ steps: [(dx: Double, seconds: Double)]) -> TimelineScrub {
        var x = width / 2, t = 100.0
        var scrub = TimelineScrub(duration: duration, start: start, width: width, x: x, at: t, drift: drift)
        for step in steps {
            let count = max(1, Int((step.seconds * 120).rounded()))
            for _ in 0 ..< count {
                x += step.dx / Double(count)
                t += 1.0 / 120
                scrub.update(x: x, at: t, fine: fine)
            }
        }
        return scrub
    }

    private static func scrubChecks(width w: Double) {
        func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }

        check(ScrubIntent.decide(dx: 0.6, dy: 0.8) == .undecided
                && ScrubIntent.decide(dx: 2.5, dy: 1) == .scrub
                && ScrubIntent.decide(dx: -3, dy: 0.5) == .scrub
                && ScrubIntent.decide(dx: 1, dy: 5) == .notAScrub
                && ScrubIntent.decide(dx: 1.5, dy: 3.5) == .undecided,
              "a click is a scrub only once it slides 2 mm sideways; up or down gives it back")

        // An 18-minute video, like a typical YouTube one.
        let video = 1106.0
        let slow = slide(duration: video, start: 100, width: w, [(10, 0.5), (0, 0.3)]).target - 100
        check(slow > 8 && slow < 35, "slow 10 mm slide on an 18-min video moves \(seconds(slow)) (precise)")
        let fine = slide(duration: video, start: 100, width: w, fine: true, [(10, 0.5), (0, 0.3)]).target - 100
        check(fine > slow * 0.2 && fine < slow * 0.3, "same slide holding ⇧⌥ moves \(seconds(fine)) (a quarter)")
        let quick = slide(duration: video, start: 100, width: w, [(60, 0.4), (0, 0.2)]).target - 100
        check(quick > 400, "quick 60 mm swipe moves \(seconds(quick)) (crosses most of the video)")
        let back = slide(duration: video, start: 600, width: w, [(-10, 0.5), (0, 0.3)]).target - 600
        check(abs(back + slow) < 1, "sliding back moves the same amount the other way (\(seconds(back)))")

        // A two-hour movie: slow slides stay precise.
        let movie = slide(duration: 7200, start: 3000, width: w, [(10, 0.5), (0, 0.3)]).target - 3000
        check(movie > 10 && movie <= 50.5, "slow 10 mm slide on a 2-hour movie moves \(seconds(movie)) (at most 5 s per mm)")

        // A resting finger with sensor jitter must not creep.
        var x = w / 2, t = 100.0
        var still = TimelineScrub(duration: 7200, start: 3000, width: w, x: x, at: t)
        for i in 0 ..< 180 {
            t += 1.0 / 120
            x = w / 2 + 0.12 * sin(Double(i) * 0.81) + 0.08 * sin(Double(i) * 2.09)
            still.update(x: x, at: t)
        }
        check(abs(still.target - 3000) < 1, "resting finger with jitter on a movie drifts \(seconds(abs(still.target - 3000)))")

        let start = slide(duration: 300, start: 10, width: w, [(-80, 0.4)]).target
        let end = slide(duration: 300, start: 290, width: w, [(80, 0.4)]).target
        check(start == 0 && end == 299.5, "stops at the start and half a second before the end")

        // Letting go: a resting finger, then the little roll of lifting it.
        var lift = slide(duration: video, start: 100, width: w, [(8, 0.4), (0, 0.4)])
        let rested = lift.target
        var lx = w / 2 + 8, lt = 100.0 + 0.8
        for _ in 0 ..< 5 {
            lx += 0.24
            lt += 1.0 / 120
            lift.update(x: lx, at: lt)
        }
        let settled = lift.settledTarget(at: lt + 0.005)
        check(lift.target - rested > 0.4 && abs(settled - rested) < 0.3,
              "the roll of lifting the finger is ignored (moved \(seconds(lift.target - rested)), lands \(seconds(settled - rested)) off)")

        let live = slide(duration: 600, start: 100, width: w, drift: 1, [(0, 1)]).target
        check(abs(live - 101) < 0.05, "while the video plays along, the position keeps moving (\(seconds(live - 100)) in 1 s)")

        let song = 200.0
        print("  on this trackpad (\(Int(w)) mm wide), per mm: song "
              + String(format: "%.1f–%.1f s", TimelineScrub.secondsPerMM(speed: 0, duration: song, width: w),
                       TimelineScrub.secondsPerMM(speed: 300, duration: song, width: w))
              + ", 18-min video " + String(format: "%.1f–%.1f s", TimelineScrub.secondsPerMM(speed: 0, duration: video, width: w),
                                           TimelineScrub.secondsPerMM(speed: 300, duration: video, width: w))
              + ", movie " + String(format: "%.1f–%.1f s", TimelineScrub.secondsPerMM(speed: 0, duration: 7200, width: w),
                                     TimelineScrub.secondsPerMM(speed: 300, duration: 7200, width: w))
              + " (slow–quick)")

        let liveStream = NowPlaying(json: ["type": "info", "duration": Double.infinity, "playing": true])
        let loading = NowPlaying(json: ["type": "info", "duration": 300, "elapsed": Double.nan, "rate": Double.nan, "playing": true])
        check(liveStream == nil && loading?.elapsed == 0 && loading?.rate == 1,
              "Now Playing info with endless or missing numbers is read safely")
    }

    // MARK: Media helper

    private static func mediaChecks() {
        guard MediaHelper.resources() != nil else {
            check(false, "media helper files (set EDGEPAL_RESOURCES or run from the .app)")
            return
        }
        var probe: [String: Any]?
        MediaHelper.shared.onMessage = { json in
            if json["type"] as? String == "probe" { probe = json }
        }
        MediaHelper.shared.start()
        MediaHelper.shared.refresh()
        MediaHelper.shared.probe()
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        check(MediaHelper.shared.isRunning, "media helper running")
        let loading = probe?["loading"] as? [String: Any]
        check(probe?["live"] as? String == "none"
                && (loading?["elapsed"] as? NSNumber)?.doubleValue == 0
                && (loading?["rate"] as? NSNumber)?.doubleValue == 1,
              "media helper copes with a live stream and a position that isn't a number")
        MediaHelper.shared.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        check(MediaHelper.shared.isRunning, "media helper still running afterwards")
        if let now = MediaHelper.shared.current {
            let app = now.pid > 0 ? NSRunningApplication(processIdentifier: now.pid)?.localizedName : nil
            print("  now playing: \(now.title) — \(formatTime(now.position())) / \(formatTime(now.duration))"
                  + (now.playing ? ", playing" : ", paused") + (app.map { " in \($0)" } ?? ""))
        } else {
            print("  now playing: nothing (bottom edge stays a normal click)")
        }
        MediaHelper.shared.onMessage = nil
        MediaHelper.shared.stop()
    }
}
