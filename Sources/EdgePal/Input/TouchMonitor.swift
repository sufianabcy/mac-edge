// EdgePal: keeps the latest finger positions of every trackpad.
import AppKit
import EdgeTouch
import QuartzCore

struct Finger {
    var id: Int32
    var state: Int32
    /// Millimetres from the left edge.
    var x: Double
    /// Millimetres from the bottom edge.
    var y: Double
    var size: Float

    /// Pressing on the surface (not hovering, not lifted).
    var isDown: Bool { state >= ETStateMakeTouch.rawValue && state <= ETStateBreakTouch.rawValue }
}

struct TouchFrame {
    var device: UInt
    var fingers: [Finger]
    var widthMM: Double
    var heightMM: Double
    /// CACurrentMediaTime() when the frame arrived.
    var receivedAt: CFTimeInterval

    var down: [Finger] { fingers.filter(\.isDown) }
}

final class TouchMonitor {
    static let shared = TouchMonitor()

    /// Called on MultitouchSupport's thread for every frame. Keep it quick.
    var frameHandler: ((TouchFrame) -> Void)?

    private let lock = NSLock()
    private var latest: [UInt: TouchFrame] = [:]
    private var sizes: [UInt: (Double, Double)] = [:]
    private var attachedCount: Int32 = 0
    private var pollTimer: Timer?
    private(set) var deviceCount: Int32 = 0

    private init() {}

    @discardableResult
    func start() -> Int32 {
        guard ETLoad() else { return 0 }
        lock.lock()
        latest = [:]
        sizes = [:]
        lock.unlock()
        deviceCount = ETStart { device, touches, count, _ in
            TouchMonitor.shared.receive(device: UInt(device), touches: touches, count: Int(count))
        }
        attachedCount = ETAttachedCount()
        if pollTimer == nil {
            // A Magic Trackpad can come and go. Check now and then, and after sleep.
            pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.restartIfDevicesChanged()
            }
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.start()
            }
        }
        return deviceCount
    }

    func stop() {
        ETStop()
        deviceCount = 0
    }

    /// The trackpad touched most recently, as long as that frame is fresh.
    func snapshot(maxAge: CFTimeInterval = 0.3) -> TouchFrame? {
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        return latest.values
            .filter { now - $0.receivedAt <= maxAge && !$0.down.isEmpty }
            .max { $0.receivedAt < $1.receivedAt }
    }

    private func restartIfDevicesChanged() {
        let count = ETAttachedCount()
        if count != attachedCount {
            start()
        }
    }

    private func receive(device: UInt, touches: UnsafePointer<ETTouch>?, count: Int) {
        lock.lock()
        let size: (Double, Double)
        if let known = sizes[device] {
            size = known
        } else {
            var w = 0.0, h = 0.0
            size = ETDeviceSize(UInt(device), &w, &h) ? (w, h) : (160, 100)
            sizes[device] = size
        }
        lock.unlock()

        var fingers: [Finger] = []
        if let touches, count > 0 {
            fingers.reserveCapacity(count)
            for i in 0 ..< count {
                let t = touches[i]
                fingers.append(Finger(id: t.identifier, state: t.state,
                                      x: Double(t.x) * size.0, y: Double(t.y) * size.1, size: t.size))
            }
        }
        let frame = TouchFrame(device: device, fingers: fingers, widthMM: size.0, heightMM: size.1,
                               receivedAt: CACurrentMediaTime())
        lock.lock()
        latest[device] = frame
        lock.unlock()
        frameHandler?(frame)
    }
}
