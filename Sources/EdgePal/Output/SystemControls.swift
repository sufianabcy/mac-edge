// EdgePal: pressing media keys, key combinations, brightness and haptics.
import AppKit
import CoreGraphics
import EdgeTouch

/// The special keys on a Mac keyboard (NX_KEYTYPE_* in IOKit's ev_keymap.h).
enum MediaKey: Int {
    case volumeUp = 0
    case volumeDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case playPause = 16
}

enum SystemControls {
    /// Presses a media key exactly like the keyboard does, so macOS shows its own indicator.
    /// `fine` holds ⇧⌥ for quarter steps.
    static func press(_ key: MediaKey, fine: Bool = false) {
        let extra: NSEvent.ModifierFlags = fine ? [.shift, .option] : []
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let flags = NSEvent.ModifierFlags(rawValue: extra.rawValue | UInt(state << 8))
            let data1 = (key.rawValue << 16) | (state << 8)
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Presses a key combination such as ⇧⌘5.
    static func pressCombo(keyCode: Int, modifiers: UInt64) {
        guard keyCode >= 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: modifiers)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// A tick from the Taptic Engine of the trackpad the finger is on.
    static func tick(device: UInt, strength: Int? = nil) {
        let settings = Settings.shared
        guard settings.haptics else { return }
        let level = Int32(strength ?? settings.hapticStrength)
        if !ETActuate(device, level) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
    }

    static var builtInDisplay: CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.first { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// Brightness of the built-in screen through DisplayServices. Only used when this Mac ignores
/// the brightness keys EdgePal presses (then there's no on-screen indicator, but it still works).
enum Brightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let functions: (GetFn, SetFn)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: GetFn.self), unsafeBitCast(set, to: SetFn.self))
    }()

    static func get() -> Float? {
        guard let (get, _) = functions, let display = SystemControls.builtInDisplay else { return nil }
        var value: Float = 0
        return get(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let (_, set) = functions, let display = SystemControls.builtInDisplay else { return }
        _ = set(display, min(1, max(0, value)))
    }

    /// One keyboard step is 1/16, a fine step 1/64.
    static func step(up: Bool, fine: Bool) {
        guard let now = get() else { return }
        let amount: Float = fine ? 1 / 64 : 1 / 16
        set(now + (up ? amount : -amount))
    }
}
