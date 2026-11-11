// EdgePal: turns a finger sliding along the bottom edge into a position in the video.
//
// Plain arithmetic, no AppKit, so `EdgePal --selftest` can check how it feels in numbers.
import Foundation

/// What a click on the bottom edge turns out to be, told apart by the first few millimetres
/// the finger moves while the trackpad is held down.
enum ScrubIntent: Equatable {
    /// Hasn't moved enough to tell yet.
    case undecided
    /// Sliding sideways: scrub the timeline.
    case scrub
    /// Moving up or down: a normal click or drag, handed to the app under the pointer.
    case notAScrub

    /// Sideways travel (mm) that starts a scrub.
    static let slideMM = 2.0
    /// Up or down travel (mm) that gives the click back.
    static let otherMM = 4.0

    static func decide(dx: Double, dy: Double) -> ScrubIntent {
        if abs(dx) >= slideMM, abs(dx) >= abs(dy) { return .scrub }
        if abs(dy) >= otherMM, abs(dy) > abs(dx) { return .notAScrub }
        return .undecided
    }
}

/// The 1€ filter (Casiez, Roussel and Vogel, CHI 2012). A slow finger gets strong smoothing, so
/// sensor jitter doesn't nudge the video; a fast finger gets almost none, so there's no lag.
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double
    private(set) var value: Double?
    /// Smoothed speed, in units per second.
    private(set) var speed = 0.0
    private var raw = 0.0
    private var time = 0.0

    init(minCutoff: Double, beta: Double, derivativeCutoff: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    @discardableResult
    mutating func filter(_ x: Double, at t: Double) -> Double {
        guard let previous = value else {
            value = x
            raw = x
            time = t
            return x
        }
        guard t > time else { return previous }
        let dt = t - time
        // Speed from the raw positions, as in the reference implementation. (From the smoothed
        // ones it would count the filter's own lag as movement and come out about 3× too fast.)
        speed += Self.alpha(cutoff: derivativeCutoff, dt: dt) * ((x - raw) / dt - speed)
        let smoothed = previous + Self.alpha(cutoff: minCutoff + beta * abs(speed), dt: dt) * (x - previous)
        value = smoothed
        raw = x
        time = t
        return smoothed
    }
}

/// One scrub: where the video should be, given how the finger has moved since it started.
struct TimelineScrub {
    let duration: Double
    /// Half a second before the end, so a scrub never finishes the video by accident.
    let end: Double
    /// Trackpad width in mm.
    let width: Double
    /// The Timeline speed setting: 1 is normal.
    let sensitivity: Double
    /// Seconds the video moves by itself per second: its playback rate when it plays along
    /// while scrubbing, otherwise 0.
    let drift: Double
    private(set) var target: Double
    private var filter = OneEuroFilter(minCutoff: 2.5, beta: 0.08, derivativeCutoff: 4)
    private var lastX: Double
    private var lastTime: Double
    /// The last half second: when each frame came, how far it moved the video, how fast the finger was.
    private var recent: [(time: Double, seconds: Double, speed: Double)] = []

    init(duration: Double, start: Double, width: Double, x: Double, at time: Double,
         sensitivity: Double = 1, drift: Double = 0) {
        self.duration = duration
        end = max(0, duration - 0.5)
        self.width = max(width, 40)
        self.sensitivity = min(max(sensitivity, 0.25), 4)
        self.drift = drift
        target = min(max(0, start), end)
        lastX = x
        lastTime = time
        filter.filter(x, at: time)
    }

    /// Seconds of video per millimetre of finger travel. Slow slides are precise (even a long
    /// movie moves at most 5 s per mm); quick ones speed up until the whole video fits in two
    /// thirds of the trackpad, like pointer acceleration.
    static func secondsPerMM(speed: Double, duration: Double, width: Double) -> Double {
        let slow = min(max(duration / (width * 4), 0.15), 5)
        let fast = max(slow, duration / (width * 0.66))
        // 20 mm/s or slower is a careful slide; 150 mm/s or faster is a swipe.
        let t = min(max((abs(speed) - 20) / 130, 0), 1)
        let eased = t * t * (3 - 2 * t)
        return slow * pow(fast / slow, eased)
    }

    mutating func update(x: Double, at time: Double, fine: Bool = false) {
        guard time > lastTime else { return }
        let smoothX = filter.filter(x, at: time)
        let gain = Self.secondsPerMM(speed: filter.speed, duration: duration, width: width)
            * sensitivity * (fine ? 0.25 : 1)
        let moved = clamp(target + (smoothX - lastX) * gain) - target
        target = clamp(target + moved + drift * (time - lastTime))
        recent.append((time, moved, abs(filter.speed)))
        recent.removeAll { time - $0.time > 0.5 }
        lastX = smoothX
        lastTime = time
    }

    /// Where the video is meant to be at `time`, counting its own playback since the last frame.
    func target(at time: Double) -> Double {
        clamp(target + drift * max(0, time - lastTime))
    }

    /// Where to land when the click lets go. Lifting a finger rolls its contact point a little,
    /// so if the finger was resting just before, its last 80 ms of movement don't count.
    func settledTarget(at time: Double) -> Double {
        let now = target(at: time)
        let age = { (entry: (time: Double, seconds: Double, speed: Double)) in time - entry.time }
        let before = recent.filter { age($0) > Self.releaseWindow && age($0) <= Self.releaseWindow + 0.15 }
        guard !before.isEmpty, before.allSatisfy({ $0.speed < Self.restingSpeed }) else { return now }
        let wobble = recent.filter { age($0) <= Self.releaseWindow }.reduce(0) { $0 + $1.seconds }
        return clamp(now - wobble)
    }

    static let releaseWindow = 0.08
    /// mm/s: slower than this, the finger is resting.
    static let restingSpeed = 12.0

    /// Which haptic detent an offset (seconds moved by the finger) is in: one every 1/40 of the
    /// video, but never closer together than 5 seconds.
    static func detent(_ offset: Double, duration: Double) -> Int {
        Int((offset / max(duration / 40, 5)).rounded(.down))
    }

    private func clamp(_ value: Double) -> Double { min(max(0, value), end) }
}
