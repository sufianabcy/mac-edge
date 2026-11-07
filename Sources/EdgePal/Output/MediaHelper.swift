// EdgePal: knows what's playing and can jump to a position in it.
//
// macOS only lets Apple's own programs read Now Playing info (since 15.4), so EdgePal runs
// /usr/bin/perl with Support/media-helper.pl, which loads libEdgePalMedia.dylib. They talk in
// JSON lines over pipes. See Sources/EdgePalMedia/EdgePalMedia.m.
import Foundation

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    var rate: Double
    var timestamp: Date
    var playing: Bool

    /// Where playback is right now, counting the time since the info was sent.
    func position(at now: Date = Date()) -> Double {
        let moved = playing ? max(0, now.timeIntervalSince(timestamp)) * rate : 0
        return min(duration, max(0, elapsed + moved))
    }
}

final class MediaHelper {
    static let shared = MediaHelper()

    private(set) var current: NowPlaying?
    private(set) var isRunning = false
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts = 0

    private init() {}

    /// Finds the helper next to the app (or in EDGEPAL_RESOURCES while developing).
    static func resources() -> (script: URL, library: URL)? {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["EDGEPAL_RESOURCES"] {
            dirs.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL { dirs.append(res) }
        for dir in dirs {
            let script = dir.appendingPathComponent("media-helper.pl")
            let library = dir.appendingPathComponent("libEdgePalMedia.dylib")
            if FileManager.default.fileExists(atPath: script.path),
               FileManager.default.fileExists(atPath: library.path) {
                return (script, library)
            }
        }
        return nil
    }

    func start() {
        guard process == nil else { return }
        guard let files = MediaHelper.resources() else {
            lastError = "media helper not found"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [files.script.path, files.library.path]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.helperExited() }
        }
        do {
            try p.run()
            process = p
            input = stdin.fileHandleForWriting
            isRunning = true
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        restarts = .max
        process?.terminate()
    }

    /// Asks for fresh info (it also arrives by itself whenever something changes).
    func refresh() { send("get") }

    func seek(to seconds: Double) {
        send(String(format: "seek %.3f", max(0, seconds)))
        if var info = current {
            info.elapsed = seconds
            info.timestamp = Date()
            current = info
        }
    }

    private func send(_ line: String) {
        guard let input, let data = (line + "\n").data(using: .utf8) else { return }
        try? input.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            handle(line: Data(line))
        }
    }

    private func handle(line: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "info":
            current = NowPlaying(
                title: json["title"] as? String ?? "",
                artist: json["artist"] as? String ?? "",
                duration: json["duration"] as? Double ?? 0,
                elapsed: json["elapsed"] as? Double ?? 0,
                rate: json["rate"] as? Double ?? 0,
                timestamp: Date(timeIntervalSince1970: json["timestamp"] as? Double ?? Date().timeIntervalSince1970),
                playing: json["playing"] as? Bool ?? false)
            restarts = 0
            onChange?()
        case "none":
            current = nil
            onChange?()
        case "error":
            lastError = json["message"] as? String
        default:
            break
        }
    }

    private func helperExited() {
        process = nil
        input = nil
        isRunning = false
        current = nil
        guard restarts < 5 else { return }
        restarts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts) * 2) { [weak self] in
            self?.start()
        }
    }
}
