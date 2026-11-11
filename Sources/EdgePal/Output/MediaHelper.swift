// EdgePal: knows what's playing and can jump to a position in it.
//
// macOS only lets Apple's own programs read Now Playing info (since 15.4), so EdgePal runs
// /usr/bin/perl with Support/media-helper.pl, which loads libEdgePalMedia.dylib. They talk in
// JSON lines over pipes. See Sources/EdgePalMedia/EdgePalMedia.m.
import AppKit

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var duration: Double
    var elapsed: Double
    var rate: Double
    var timestamp: Date
    var playing: Bool
    /// The app that's playing, or 0 if unknown.
    var pid: Int32 = 0

    /// Live streams have no end to scrub to, and a blip of a sound isn't worth scrubbing.
    var canScrub: Bool { duration.isFinite && duration > 1 }

    /// Seconds of media per second of time: the playback rate while playing, otherwise 0.
    var speed: Double { playing ? rate : 0 }

    /// Where playback is right now, counting the time since the info was sent.
    func position(at now: Date = Date()) -> Double {
        let moved = max(0, now.timeIntervalSince(timestamp)) * speed
        return min(duration, max(0, elapsed + moved))
    }
}

extension NowPlaying {
    /// Reads an "info" line from the helper. Anything missing or not a finite number gets a
    /// safe value; without a usable duration there's nothing to scrub, so it's nil.
    init?(json: [String: Any]) {
        func number(_ key: String) -> Double? {
            guard let value = (json[key] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
            return value
        }
        guard let duration = number("duration"), duration > 0 else { return nil }
        let playing = (json["playing"] as? NSNumber)?.boolValue ?? false
        let rate = number("rate") ?? (playing ? 1 : 0)
        self.init(title: json["title"] as? String ?? "",
                  artist: json["artist"] as? String ?? "",
                  duration: duration,
                  elapsed: min(max(number("elapsed") ?? 0, 0), duration),
                  rate: playing && rate <= 0 ? 1 : rate,
                  timestamp: number("timestamp").map { Date(timeIntervalSince1970: $0) } ?? Date(),
                  playing: playing,
                  pid: (json["pid"] as? NSNumber)?.int32Value ?? 0)
    }
}

final class MediaHelper {
    static let shared = MediaHelper()

    private(set) var current: NowPlaying?
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Every line from the helper that isn't Now Playing info (the self-test reads "probe" here).
    var onMessage: (([String: Any]) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var failures = 0
    private var startedAt = Date.distantPast
    private var stopped = false

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
        stopped = false
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
            guard !data.isEmpty else {
                // End of file: the helper is gone. Left in place, this handler would be called
                // over and over and keep a CPU core busy.
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { self?.consume(data) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.helperExited() }
        }
        do {
            try p.run()
            process = p
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
            startedAt = Date()
            isRunning = true
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            lastError = error.localizedDescription
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
    }

    /// Asks for fresh info (it also arrives by itself whenever something changes).
    func refresh() { send("get") }

    /// Self-test: the helper answers with how it cleans up numbers it can't use.
    func probe() { send("probe") }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        send(String(format: "seek %.3f", max(0, seconds)))
        if var info = current {
            info.elapsed = min(max(0, seconds), info.duration)
            info.timestamp = Date()
            current = info
        }
    }

    private func send(_ line: String) {
        // EdgePal ignores SIGPIPE (see main.swift), so writing to a helper that just died
        // fails quietly here instead of ending EdgePal.
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
            current = NowPlaying(json: json)
        case "none":
            current = nil
        case "error":
            lastError = json["message"] as? String
        default:
            onMessage?(json)
        }
    }

    private func helperExited() {
        output?.readabilityHandler = nil
        output = nil
        process = nil
        input = nil
        buffer = Data()
        isRunning = false
        current = nil
        guard !stopped else { return }
        // Start it again: quickly after a one-off crash, then less and less often if it keeps
        // failing, but never give up for good (that left the bottom edge dead until EdgePal
        // restarted). A helper that ran for a while starts the count again.
        if Date().timeIntervalSince(startedAt) > 30 { failures = 0 }
        failures += 1
        let delay = min(pow(2, Double(failures)), 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.start()
        }
    }
}
