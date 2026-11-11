// EdgePal: the heart of the app.
//
// An event tap sees every left click. When a click starts with exactly one finger inside an
// edge strip, EdgePal keeps that click from reaching apps, freezes the pointer, and turns the
// finger's movement (read from MultitouchSupport) into volume, brightness, a video scrub or a
// corner shortcut. Anything else passes straight through, so the middle of the trackpad,
// palms, typing and scrolling behave exactly as before.
//
// Many people click with a thumb near the bottom of the trackpad, so a click on the bottom
// edge is only held back until the finger shows what it wants: sliding sideways scrubs the
// timeline, anything else gives the click back to the app as if EdgePal weren't there.
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

    /// Marks the clicks EdgePal gives back to apps, so its own tap lets them through.
    static let replayMarker: Int64 = 0x4544_4745 // "EDGE"

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

    private enum Phase {
        /// Bottom edge: the click is held back until the finger slides sideways (a scrub) or not.
        case deciding
        case active
        /// Not a gesture after all: the click went to the app, and EdgePal stays out of the way
        /// until the button comes up.
        case handedBack
    }

    private struct Gesture {
        var job: Job
        var zone: Zone
        var phase: Phase
        var device: UInt
        var finger: Int32
        var width: Double
        var edge: Double
        var cursor: CGPoint
        var startX: Double
        var startY: Double
        var lastSeen: CFTimeInterval
        var cancelled = false
        /// The mouse-down EdgePal kept, to give back if this turns out not to be a scrub.
        var heldDown: CGEvent?
        // Sliders
        var anchorY = 0.0
        var steps = 0
        // Timeline
        var scrub: TimelineScrub?
        var engagedAt: CFTimeInterval = 0
        /// Where the video was when the scrub began, and how fast it plays by itself.
        var origin = 0.0
        var playSpeed = 0.0
        /// The video follows the finger (Settings › Move the video while sliding).
        var live = false
        var detent = 0
        var lastTick: CFTimeInterval = 0
        var atLimit = false
        /// The last position sent to the player while scrubbing live.
        var sent: (target: Double, at: CFTimeInterval)?
    }

    private var gesture: Gesture?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var liveSeekTimer: Timer?

    // Shared with MultitouchSupport's thread.
    private let lock = NSLock()
    private var trackingDevice: UInt?
    private var pendingFrame: TouchFrame?
    private var drainScheduled = false
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
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        // A click EdgePal gave back to apps.
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker { return pass }
        let phase = gesture?.phase
        switch type {
        case .leftMouseDown:
            if phase == .handedBack {
                endTracking() // Its mouse-up went missing; this is a new click.
            } else if phase != nil {
                return nil
            }
            return begin(event) ? nil : pass
        case .leftMouseDragged:
            return phase == nil || phase == .handedBack ? pass : nil
        case .leftMouseUp:
            switch phase {
            case nil:
                return pass
            case .handedBack?:
                endTracking()
                return pass
            case .deciding?:
                giveClickBack(up: event)
                return nil
            case .active?:
                finish(normally: true)
                return nil
            }
        default:
            // Force Touch pressure belongs to the click we kept.
            return type.rawValue == 34 && phase != nil && phase != .handedBack ? nil : pass
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

        var g = Gesture(job: job, zone: zone, phase: .active, device: frame.device, finger: finger.id,
                        width: layout.width, edge: layout.edge, cursor: event.location,
                        startX: finger.x, startY: finger.y, lastSeen: CACurrentMediaTime())
        switch job {
        case .volume, .brightness:
            g.anchorY = finger.y
            report(job == .volume ? "Volume: slide up or down" : "Brightness: slide up or down")
        case .timeline:
            // Nothing shows yet: the click is held back until the finger slides sideways.
            g.phase = .deciding
            g.heldDown = event.copy()
            MediaHelper.shared.refresh() // So the position is fresh when the slide starts.
        case .corner:
            break
        }
        if case .corner = job {} else {
            // The pointer stays exactly where it was while the finger slides.
            CGAssociateMouseAndMouseCursorPosition(0)
        }
        gesture = g
        lock.lock(); trackingDevice = frame.device; pendingFrame = nil; lock.unlock()
        if g.phase == .active { SystemControls.tick(device: frame.device, strength: 1) }
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
                if s.timelineEdge, MediaHelper.shared.current?.canScrub == true {
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

    /// The finger didn't slide: give the app the click it would have had without EdgePal.
    private func giveClickBack(up: CGEvent) {
        guard let g = gesture else { return }
        endTracking()
        unfreeze(g)
        if let down = g.heldDown, let up = up.copy() {
            // Posted in order, after the real mouse-up was kept back, so the app sees down then up.
            for event in [down, up] {
                event.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
                event.post(tap: .cgSessionEventTap)
            }
        }
        report("Bottom edge: a plain click, passed to the app")
    }

    /// The finger moved up or down rather than sideways: it's a normal click or drag. The app gets
    /// the mouse-down now, then everything after it, as if EdgePal weren't there.
    private func handBack(_ g: inout Gesture) {
        g.phase = .handedBack
        lock.lock(); trackingDevice = nil; pendingFrame = nil; lock.unlock()
        unfreeze(g)
        if let down = g.heldDown {
            down.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
            down.post(tap: .cgSessionEventTap)
        }
        g.heldDown = nil
        report("Bottom edge: not a slide, the click went to the app")
    }

    // MARK: Finger movement

    /// MultitouchSupport's thread, 90 or more times a second. Only the newest frame matters, so
    /// frames are merged: the main thread never works through a backlog of old ones.
    private func received(_ frame: TouchFrame) {
        lock.lock()
        var drain = false
        if trackingDevice == frame.device {
            pendingFrame = frame
            if !drainScheduled {
                drainScheduled = true
                drain = true
            }
        }
        var preview = false
        if wantsPreview, frame.receivedAt - lastPreview > 1.0 / 30 || frame.fingers.isEmpty {
            lastPreview = frame.receivedAt
            preview = true
        }
        lock.unlock()
        if drain { DispatchQueue.main.async { self.drainFrames() } }
        if preview { DispatchQueue.main.async { self.previewHandler?(frame) } }
    }

    private func drainFrames() {
        lock.lock()
        let frame = pendingFrame
        pendingFrame = nil
        drainScheduled = false
        lock.unlock()
        if let frame { track(frame) }
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
            switch g.phase {
            case .deciding:
                switch ScrubIntent.decide(dx: f.x - g.startX, dy: f.y - g.startY) {
                case .undecided: break
                case .notAScrub: handBack(&g)
                case .scrub: engageTimeline(&g, x: f.x, at: frame.receivedAt)
                }
            case .active:
                scrubTimeline(&g, finger: f, at: frame.receivedAt, fine: fine)
            case .handedBack:
                break
            }
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

    // MARK: Timeline

    /// The finger slid sideways: from here on it's a scrub.
    private func engageTimeline(_ g: inout Gesture, x: Double, at time: CFTimeInterval) {
        guard let media = MediaHelper.shared.current, media.canScrub else {
            handBack(&g)
            return
        }
        let settings = Settings.shared
        let origin = media.position()
        g.phase = .active
        g.heldDown = nil
        g.engagedAt = time
        g.origin = origin
        g.playSpeed = media.speed
        g.live = settings.liveScrub
        g.scrub = TimelineScrub(duration: media.duration, start: origin, width: g.width, x: x, at: time,
                                sensitivity: settings.scrubSpeed,
                                drift: g.live ? media.speed : 0)
        g.detent = 0
        g.atLimit = origin <= 0 || origin >= max(0, media.duration - 0.5) // No bump for where it starts.
        ScrubHUD.shared.show(media: media, at: origin, live: settings.liveScrub)
        SystemControls.tick(device: g.device, strength: 1)
        report(settings.liveScrub ? "Timeline: the video follows your finger" : "Timeline: let go to jump")
    }

    private func scrubTimeline(_ g: inout Gesture, finger f: Finger, at time: CFTimeInterval, fine: Bool) {
        guard var scrub = g.scrub else { return }
        if f.y > g.edge * 2.5 {
            cancelTimeline(&g)
            return
        }
        scrub.update(x: f.x, at: time, fine: fine)
        g.scrub = scrub
        let target = scrub.target
        // Where the video would be without the scrub: it moves on by itself while playing along.
        let reference = min(g.origin + scrub.drift * (time - g.engagedAt), scrub.end)
        // A detent every so often as the finger moves the video (not as it plays on by itself),
        // and a firmer bump on reaching the start or the end.
        let detent = TimelineScrub.detent(target - reference, duration: scrub.duration)
        let atLimit = target <= 0 || target >= scrub.end
        if atLimit, !g.atLimit {
            SystemControls.tick(device: g.device, strength: 3)
            g.lastTick = time
        } else if detent != g.detent, time - g.lastTick > 0.03 {
            SystemControls.tick(device: g.device)
            g.lastTick = time
        }
        g.detent = detent
        g.atLimit = atLimit
        ScrubHUD.shared.update(target: target, reference: reference, fine: fine)
        if g.live { liveSeek(&g, at: time) }
    }

    /// While scrubbing live the video follows the finger, with at most one seek every 0.15 s (a
    /// player can't show new frames any faster) and always the latest position in the end.
    private static let liveSeekInterval: CFTimeInterval = 0.15

    private func liveSeek(_ g: inout Gesture, at time: CFTimeInterval) {
        guard let scrub = g.scrub else { return }
        let target = scrub.target(at: time)
        guard abs(target - playerPosition(g, at: time)) >= 0.25 else { return }
        let wait = (g.sent.map { $0.at + Self.liveSeekInterval } ?? 0) - time
        if wait <= 0 {
            MediaHelper.shared.seek(to: target)
            g.sent = (target, time)
        } else if liveSeekTimer == nil {
            let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.liveSeekTimer = nil
                guard var g = self.gesture, g.phase == .active, !g.cancelled else { return }
                self.liveSeek(&g, at: CACurrentMediaTime())
                self.gesture = g
            }
            RunLoop.main.add(timer, forMode: .common)
            liveSeekTimer = timer
        }
    }

    /// Where the player should be now: the last position sent to it (or where it was when the
    /// scrub began), plus whatever it has played since.
    private func playerPosition(_ g: Gesture, at time: CFTimeInterval) -> Double {
        if let sent = g.sent { return sent.target + g.playSpeed * (time - sent.at) }
        return g.origin + g.playSpeed * (time - g.engagedAt)
    }

    /// Slid up off the edge: nothing changes, and a video that followed the finger goes back.
    private func cancelTimeline(_ g: inout Gesture) {
        g.cancelled = true
        liveSeekTimer?.invalidate()
        liveSeekTimer = nil
        let back = min(max(0, g.origin + g.playSpeed * (CACurrentMediaTime() - g.engagedAt)),
                       g.scrub?.end ?? g.origin)
        if g.sent != nil {
            MediaHelper.shared.seek(to: back)
        }
        ScrubHUD.shared.finish(.cancelled, at: back)
        SystemControls.tick(device: g.device, strength: 1)
        report("Timeline: cancelled, the video is where it was")
    }

    private func finishTimeline(_ g: Gesture, normally: Bool) {
        guard !g.cancelled, let scrub = g.scrub else { return }
        let now = CACurrentMediaTime()
        guard normally else {
            // Lost track of the click: leave the video wherever it is now.
            ScrubHUD.shared.finish(g.sent == nil ? .cancelled : .landed, at: playerPosition(g, at: now))
            return
        }
        let landing = scrub.settledTarget(at: now)
        // When the video already followed the finger there's usually nothing left to do.
        if abs(landing - playerPosition(g, at: now)) > 0.35 {
            MediaHelper.shared.seek(to: landing)
        }
        ScrubHUD.shared.finish(.landed, at: landing)
        report("Timeline: \(formatTime(landing)) of \(formatTime(scrub.duration))")
    }

    // MARK: Finishing

    private func finish(normally: Bool) {
        guard let g = gesture else { return }
        endTracking()
        switch g.phase {
        case .handedBack:
            return // The app has the click; the pointer is already free.
        case .deciding:
            // Its mouse-up went missing, so the click can't be given back. Just let go.
            unfreeze(g)
            return
        case .active:
            break
        }
        switch g.job {
        case .timeline:
            finishTimeline(g, normally: normally)
        case .corner(let corner):
            if normally { CornerClicks.shared.click(corner) }
        case .volume, .brightness:
            break
        }
        if case .corner = g.job { return }
        unfreeze(g)
    }

    /// Forgets the current gesture. The caller decides what happens to the click and the pointer.
    private func endTracking() {
        gesture = nil
        lock.lock(); trackingDevice = nil; pendingFrame = nil; lock.unlock()
        watchdog?.invalidate()
        watchdog = nil
        liveSeekTimer?.invalidate()
        liveSeekTimer = nil
    }

    /// Lets the pointer move again, exactly where it was.
    private func unfreeze(_ g: Gesture) {
        // Warping mutes the trackpad for a moment, so only warp if the pointer really moved.
        if let now = CGEvent(source: nil)?.location, hypot(now.x - g.cursor.x, now.y - g.cursor.y) > 0.5 {
            CGWarpMouseCursorPosition(g.cursor)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Never leave the pointer frozen: if the button is up and we missed it, finish anyway.
    private func startWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let g = self.gesture else { return }
            let buttonDown = CGEventSource.buttonState(.hidSystemState, button: .left)
            if g.phase == .handedBack {
                if !buttonDown { self.endTracking() }
                return
            }
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
