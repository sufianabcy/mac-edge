// EdgePal: the heart of the app.
//
// An event tap sees every left click. When a click starts with exactly one finger inside an
// edge strip, EdgePal keeps that click from reaching apps, freezes the pointer, and turns the
// finger's movement (read from MultitouchSupport) into volume, brightness, a video scrub or a
// corner shortcut. Anything else passes straight through, so the middle of the trackpad,
// palms, typing and scrolling behave exactly as before.
import AppKit
import ApplicationServices
import QuartzCore

enum Zone: String {
    case left, right, bottom, topLeft, topRight
}

/// Where the edge strips are on a trackpad, in millimetres.
struct ZoneLayout {
    var width: Double
    var height: Double
    var edge: Double

    init(width: Double, height: Double, edgeShare: Double) {
        self.width = width
        self.height = height
        edge = width * edgeShare
    }

    /// Every zone this point is in, most specific first (a top corner is also a side strip).
    func zones(x: Double, y: Double) -> [Zone] {
        let top = y > height - edge, bottom = y < edge
        let left = x < edge, right = x > width - edge
        var list: [Zone] = []
        if top && left { list.append(.topLeft) }
        if top && right { list.append(.topRight) }
        if bottom { list.append(.bottom) }
        if left { list.append(.left) }
        if right { list.append(.right) }
        return list
    }
}

final class EdgeEngine: ObservableObject {
    static let shared = EdgeEngine()

    /// Shown in the welcome guide and Settings so people can see what just happened.
    @Published private(set) var lastAction = "Waiting for a gesture…"
    @Published private(set) var tapRunning = false

    /// Live finger frames for the trackpad preview (main thread, about 30 per second).
    var previewHandler: ((TouchFrame) -> Void)? {
        didSet {
            lock.lock(); wantsPreview = previewHandler != nil; lock.unlock()
        }
    }

    enum Job: Equatable {
        case volume, brightness, timeline, corner(Corner)
    }

    private struct Gesture {
        var job: Job
        var zone: Zone
        var device: UInt
        var finger: Int32
        var width: Double
        var edge: Double
        var cursor: CGPoint
        var lastSeen: CFTimeInterval
        var cancelled = false
        // Sliders
        var anchorY = 0.0
        var steps = 0
        // Timeline
        var baseX = 0.0
        var basePosition = 0.0
        var startPosition = 0.0
        var target = 0.0
        var duration = 0.0
        var tickIndex = 0
        var fine = false
    }

    private var gesture: Gesture?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var watchdog: Timer?

    // Read on MultitouchSupport's thread.
    private let lock = NSLock()
    private var trackingDevice: UInt?
    private var wantsPreview = false
    private var lastPreview: CFTimeInterval = 0

    private init() {}

    // MARK: Start and stop

    /// Starts reading the trackpads and the media helper, then the event tap if allowed.
    @discardableResult
    func start() -> Bool {
        TouchMonitor.shared.frameHandler = { [weak self] frame in self?.received(frame) }
        if TouchMonitor.shared.deviceCount == 0 {
            TouchMonitor.shared.start()
        }
        MediaHelper.shared.start()
        return startTap()
    }

    /// The event tap needs Accessibility permission. Safe to call again and again.
    @discardableResult
    func startTap() -> Bool {
        if tap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        var mask: CGEventMask = 0
        for type in [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged] {
            mask |= 1 << CGEventMask(type.rawValue)
        }
        mask |= 1 << 34 // NSEvent.EventType.pressure: Force Touch pressure while clicking.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in EdgeEngine.shared.handle(type: type, event: event) },
            userInfo: nil)
        else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
        tapRunning = true
        return true
    }

    func stopTap() {
        finish(normally: false)
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        tap = nil
        tapSource = nil
        tapRunning = false
    }

    func report(_ text: String) {
        if Thread.isMainThread {
            lastAction = text
        } else {
            DispatchQueue.main.async { self.lastAction = text }
        }
    }

    // MARK: Events

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .leftMouseDown:
            if gesture != nil { return nil }
            return begin(event) ? nil : pass
        case .leftMouseDragged:
            return gesture != nil ? nil : pass
        case .leftMouseUp:
            guard gesture != nil else { return pass }
            finish(normally: true)
            return nil
        default:
            // Force Touch pressure belongs to the click we kept.
            return type.rawValue == 34 && gesture != nil ? nil : pass
        }
    }

    private func begin(_ event: CGEvent) -> Bool {
        let settings = Settings.shared
        guard settings.enabled, settings.modifier.isSatisfied(by: event.flags) else { return false }
        if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           settings.pausedApps.contains(app) { return false }
        // Exactly one finger: palms and two-finger clicks are never a gesture.
        guard let frame = TouchMonitor.shared.snapshot(), frame.down.count == 1,
              let finger = frame.down.first else { return false }
        let layout = ZoneLayout(width: frame.widthMM, height: frame.heightMM, edgeShare: settings.edgeWidth)
        guard let (job, zone) = resolve(layout.zones(x: finger.x, y: finger.y)) else { return false }

        var g = Gesture(job: job, zone: zone, device: frame.device, finger: finger.id,
                        width: layout.width, edge: layout.edge, cursor: event.location,
                        lastSeen: CACurrentMediaTime())
        switch job {
        case .volume, .brightness:
            g.anchorY = finger.y
            report(job == .volume ? "Volume: slide up or down" : "Brightness: slide up or down")
        case .timeline:
            guard let now = MediaHelper.shared.current else { return false }
            g.duration = now.duration
            g.startPosition = now.position()
            g.basePosition = g.startPosition
            g.target = g.startPosition
            g.baseX = finger.x
            g.tickIndex = tickIndex(g.target, g.duration)
            ScrubHUD.shared.show(title: now.title, duration: now.duration, start: g.startPosition)
            report("Timeline: slide sideways, let go to jump")
        case .corner:
            break
        }
        if case .corner = job {} else {
            // The pointer stays exactly where it was while the finger slides.
            CGAssociateMouseAndMouseCursorPosition(0)
        }
        gesture = g
        lock.lock(); trackingDevice = frame.device; lock.unlock()
        SystemControls.tick(device: frame.device, strength: 1)
        startWatchdog()
        return true
    }

    /// Picks the first zone that has a job right now.
    private func resolve(_ zones: [Zone]) -> (Job, Zone)? {
        let s = Settings.shared
        for zone in zones {
            switch zone {
            case .topLeft, .topRight:
                let corner: Corner = zone == .topLeft ? .topLeft : .topRight
                if s.cornersEnabled, s.actions(for: corner).contains(where: \.isSet) {
                    return (.corner(corner), zone)
                }
            case .bottom:
                if s.timelineEdge, let now = MediaHelper.shared.current, now.duration > 1 {
                    return (.timeline, zone)
                }
            case .left, .right:
                let isVolume = (zone == .right) != s.swapSides
                if isVolume, s.volumeEdge { return (.volume, zone) }
                if !isVolume, s.brightnessEdge, SystemControls.builtInDisplay != nil {
                    return (.brightness, zone)
                }
            }
        }
        return nil
    }

    // MARK: Finger movement

    /// MultitouchSupport's thread.
    private func received(_ frame: TouchFrame) {
        lock.lock()
        let tracking = trackingDevice == frame.device
        var preview = false
        if wantsPreview, frame.receivedAt - lastPreview > 1.0 / 30 || frame.fingers.isEmpty {
            lastPreview = frame.receivedAt
            preview = true
        }
        lock.unlock()
        guard tracking || preview else { return }
        DispatchQueue.main.async {
            if tracking { self.track(frame) }
            if preview { self.previewHandler?(frame) }
        }
    }

    private func track(_ frame: TouchFrame) {
        guard var g = gesture, frame.device == g.device,
              let f = frame.fingers.first(where: { $0.id == g.finger && $0.isDown }) else { return }
        g.lastSeen = frame.receivedAt
        defer { gesture = g }
        guard !g.cancelled else { return }
        let fine = NSEvent.modifierFlags.contains([.shift, .option])

        switch g.job {
        case .volume, .brightness:
            // Sliding inward, off the strip, stops the gesture.
            let onLeft = g.zone == .left || g.zone == .topLeft
            let inward = onLeft ? f.x : g.width - f.x
            if inward > g.edge * 2 {
                g.cancelled = true
                report("Stopped: the finger left the edge")
                return
            }
            let step = Settings.shared.stepMM
            var moves = 0
            while abs(f.y - g.anchorY) >= step, moves < 6 {
                let up = f.y > g.anchorY
                g.anchorY += up ? step : -step
                slide(&g, up: up, fine: fine)
                moves += 1
            }
        case .timeline:
            if f.y > g.edge * 2.5 {
                g.cancelled = true
                ScrubHUD.shared.hide(cancelled: true)
                SystemControls.tick(device: g.device, strength: 1)
                report("Timeline: cancelled, the video didn't move")
                return
            }
            if fine != g.fine {
                // Re-base so switching to fine control doesn't make the preview jump.
                g.fine = fine
                g.baseX = f.x
                g.basePosition = g.target
            }
            let scale = fine ? 0.25 : 1
            let moved = (f.x - g.baseX) / g.width * g.duration * scale
            g.target = min(max(0, g.basePosition + moved), max(0, g.duration - 0.5))
            let index = tickIndex(g.target, g.duration)
            if index != g.tickIndex {
                g.tickIndex = index
                SystemControls.tick(device: g.device)
            }
            ScrubHUD.shared.update(target: g.target)
        case .corner:
            break
        }
    }

    private func slide(_ g: inout Gesture, up: Bool, fine: Bool) {
        if g.job == .volume {
            SystemControls.press(up ? .volumeUp : .volumeDown, fine: fine)
            report(up ? "Volume up" : "Volume down")
        } else {
            let settings = Settings.shared
            if settings.brightnessDirect {
                Brightness.step(up: up, fine: fine)
            } else {
                let before = Brightness.get()
                SystemControls.press(up ? .brightnessUp : .brightnessDown, fine: fine)
                // Some Macs ignore brightness keys from apps. If the first one did nothing,
                // set the brightness directly from now on.
                if g.steps == 0, let before, up ? before < 0.97 : before > 0.03 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        if let after = Brightness.get(), abs(after - before) < 0.001 {
                            settings.brightnessDirect = true
                            Brightness.step(up: up, fine: fine)
                        }
                    }
                }
            }
            report(up ? "Brightness up" : "Brightness down")
        }
        g.steps += 1
        SystemControls.tick(device: g.device)
    }

    /// A tick every 1/40 of the video, but never more often than every 5 seconds.
    private func tickIndex(_ position: Double, _ duration: Double) -> Int {
        Int(position / max(duration / 40, 5))
    }

    // MARK: Finishing

    private func finish(normally: Bool) {
        guard let g = gesture else { return }
        gesture = nil
        lock.lock(); trackingDevice = nil; lock.unlock()
        watchdog?.invalidate()
        watchdog = nil

        switch g.job {
        case .timeline:
            if normally, !g.cancelled {
                MediaHelper.shared.seek(to: g.target)
                ScrubHUD.shared.hide(cancelled: false)
                report("Jumped to \(formatTime(g.target))")
            } else {
                ScrubHUD.shared.hide(cancelled: true)
            }
        case .corner(let corner):
            if normally { CornerClicks.shared.click(corner) }
        case .volume, .brightness:
            break
        }
        if case .corner = g.job { return }
        CGWarpMouseCursorPosition(g.cursor)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Never leave the pointer frozen: if the button is up and we missed it, finish anyway.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let g = self.gesture else { return }
            let buttonDown = CGEventSource.buttonState(.hidSystemState, button: .left)
            if !buttonDown || CACurrentMediaTime() - g.lastSeen > 3 {
                self.finish(normally: !buttonDown)
            }
        }
    }

    /// Called when the app quits.
    func releasePointer() {
        finish(normally: false)
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
