// EdgePal: everything the user can change, saved in UserDefaults.
import AppKit
import Combine
import CoreGraphics

enum Corner: String, Codable, CaseIterable, Identifiable {
    case topLeft, topRight
    var id: String { rawValue }
    var title: String { self == .topLeft ? "Top-left corner" : "Top-right corner" }
}

enum ModifierRequirement: String, Codable, CaseIterable, Identifiable {
    case none, fn, control, option, command
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Nothing, just press"
        case .fn: return "Hold fn"
        case .control: return "Hold ⌃ Control"
        case .option: return "Hold ⌥ Option"
        case .command: return "Hold ⌘ Command"
        }
    }
    func isSatisfied(by flags: CGEventFlags) -> Bool {
        switch self {
        case .none: return true
        case .fn: return flags.contains(.maskSecondaryFn)
        case .control: return flags.contains(.maskControl)
        case .option: return flags.contains(.maskAlternate)
        case .command: return flags.contains(.maskCommand)
        }
    }
}

enum CornerActionKind: String, Codable, CaseIterable, Identifiable {
    case none, mute, playPause, openApp, openLink, keyCombo, shortcut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Nothing"
        case .mute: return "Mute / unmute"
        case .playPause: return "Play / pause"
        case .openApp: return "Open an app"
        case .openLink: return "Open a link, file or folder"
        case .keyCombo: return "Press a key combination"
        case .shortcut: return "Run a Shortcut"
        }
    }
}

struct CornerAction: Codable, Equatable {
    var kind: CornerActionKind = .none
    var appPath = ""
    var link = ""
    var browserPath = ""
    var keyCode: Int = -1
    var modifiers: UInt64 = 0
    var shortcutName = ""
    /// What the recorded key combination looks like, e.g. "⇧⌘5".
    var keyLabel = ""

    init(kind: CornerActionKind = .none, keyCode: Int = -1, modifiers: UInt64 = 0, keyLabel: String = "") {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    // Every field is optional when reading, so settings from older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decode(CornerActionKind.self, forKey: .kind)) ?? .none
        appPath = (try? c.decode(String.self, forKey: .appPath)) ?? ""
        link = (try? c.decode(String.self, forKey: .link)) ?? ""
        browserPath = (try? c.decode(String.self, forKey: .browserPath)) ?? ""
        keyCode = (try? c.decode(Int.self, forKey: .keyCode)) ?? -1
        modifiers = (try? c.decode(UInt64.self, forKey: .modifiers)) ?? 0
        shortcutName = (try? c.decode(String.self, forKey: .shortcutName)) ?? ""
        keyLabel = (try? c.decode(String.self, forKey: .keyLabel)) ?? ""
    }

    static let none = CornerAction()
    static let mute = CornerAction(kind: .mute)
    /// ⇧⌘5, the Screenshot toolbar.
    static let screenshot = CornerAction(
        kind: .keyCombo, keyCode: 23,
        modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue,
        keyLabel: "⇧⌘5")

    /// A one-line description for menus and the trackpad preview.
    var summary: String {
        switch kind {
        case .openApp:
            return appPath.isEmpty ? kind.title
                : "Open " + FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
        case .openLink: return link.isEmpty ? kind.title : link
        case .keyCombo: return keyLabel.isEmpty ? kind.title : "Press " + keyLabel
        case .shortcut: return shortcutName.isEmpty ? kind.title : "Run “\(shortcutName)”"
        default: return kind.title
        }
    }

    var isSet: Bool {
        switch kind {
        case .none: return false
        case .mute, .playPause: return true
        case .openApp: return !appPath.isEmpty
        case .openLink: return !link.trimmingCharacters(in: .whitespaces).isEmpty
        case .keyCombo: return keyCode >= 0
        case .shortcut: return !shortcutName.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var enabled: Bool { didSet { save("enabled", enabled) } }
    @Published var volumeEdge: Bool { didSet { save("volumeEdge", volumeEdge) } }
    @Published var brightnessEdge: Bool { didSet { save("brightnessEdge", brightnessEdge) } }
    @Published var timelineEdge: Bool { didSet { save("timelineEdge", timelineEdge) } }
    /// Bottom edge: the video moves while the finger slides (otherwise it jumps when you let go).
    @Published var liveScrub: Bool { didSet { save("liveScrub", liveScrub) } }
    /// Bottom edge: how far the video moves for the same slide. 1 is normal.
    @Published var scrubSpeed: Double { didSet { save("scrubSpeed", scrubSpeed) } }
    @Published var cornersEnabled: Bool { didSet { save("cornersEnabled", cornersEnabled) } }
    /// false: volume on the right, brightness on the left.
    @Published var swapSides: Bool { didSet { save("swapSides", swapSides) } }
    /// Width of each edge strip as a share of the trackpad width.
    @Published var edgeWidth: Double { didSet { save("edgeWidth", edgeWidth) } }
    /// How far a finger slides (mm) for one volume or brightness step.
    @Published var stepMM: Double { didSet { save("stepMM", stepMM) } }
    @Published var modifier: ModifierRequirement { didSet { save("modifier", modifier.rawValue) } }
    @Published var haptics: Bool { didSet { save("haptics", haptics) } }
    /// 1 light, 2 medium, 3 strong.
    @Published var hapticStrength: Int { didSet { save("hapticStrength", hapticStrength) } }
    /// Bundle IDs of apps where EdgePal steps aside.
    @Published var pausedApps: [String] { didSet { save("pausedApps", pausedApps) } }
    @Published var topLeft: [CornerAction] { didSet { saveCorner("topLeft", topLeft) } }
    @Published var topRight: [CornerAction] { didSet { saveCorner("topRight", topRight) } }
    @Published var finishedWelcome: Bool { didSet { save("finishedWelcome", finishedWelcome) } }
    /// Set automatically when this Mac ignores the brightness keys EdgePal presses.
    @Published var brightnessDirect: Bool { didSet { save("brightnessDirect", brightnessDirect) } }

    private init() {
        defaults.register(defaults: [
            "enabled": true, "volumeEdge": true, "brightnessEdge": true, "timelineEdge": true,
            "liveScrub": true, "scrubSpeed": 1.0,
            "cornersEnabled": true, "swapSides": false, "edgeWidth": 0.10, "stepMM": 4.0,
            "modifier": ModifierRequirement.none.rawValue, "haptics": true, "hapticStrength": 2,
            "pausedApps": [String](), "finishedWelcome": false, "brightnessDirect": false,
        ])
        enabled = defaults.bool(forKey: "enabled")
        volumeEdge = defaults.bool(forKey: "volumeEdge")
        brightnessEdge = defaults.bool(forKey: "brightnessEdge")
        timelineEdge = defaults.bool(forKey: "timelineEdge")
        liveScrub = defaults.bool(forKey: "liveScrub")
        scrubSpeed = defaults.double(forKey: "scrubSpeed")
        cornersEnabled = defaults.bool(forKey: "cornersEnabled")
        swapSides = defaults.bool(forKey: "swapSides")
        edgeWidth = defaults.double(forKey: "edgeWidth")
        stepMM = defaults.double(forKey: "stepMM")
        modifier = ModifierRequirement(rawValue: defaults.string(forKey: "modifier") ?? "") ?? .none
        haptics = defaults.bool(forKey: "haptics")
        hapticStrength = defaults.integer(forKey: "hapticStrength")
        pausedApps = defaults.stringArray(forKey: "pausedApps") ?? []
        finishedWelcome = defaults.bool(forKey: "finishedWelcome")
        brightnessDirect = defaults.bool(forKey: "brightnessDirect")
        topLeft = Settings.loadCorner(defaults, "topLeft") ?? [.mute, .none, .none, .none]
        topRight = Settings.loadCorner(defaults, "topRight") ?? [.screenshot, .none, .none, .none]
    }

    func actions(for corner: Corner) -> [CornerAction] {
        corner == .topLeft ? topLeft : topRight
    }

    func setAction(_ action: CornerAction, corner: Corner, clicks: Int) {
        var list = actions(for: corner)
        while list.count < 4 { list.append(.none) }
        list[clicks - 1] = action
        if corner == .topLeft { topLeft = list } else { topRight = list }
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    private func saveCorner(_ key: String, _ value: [CornerAction]) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func loadCorner(_ defaults: UserDefaults, _ key: String) -> [CornerAction]? {
        guard let data = defaults.data(forKey: key),
              var list = try? JSONDecoder().decode([CornerAction].self, from: data) else { return nil }
        while list.count < 4 { list.append(.none) }
        return Array(list.prefix(4))
    }
}
