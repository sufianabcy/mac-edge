// EdgePal: the panel that shows where the video is going while a finger scrubs the bottom edge.
import AppKit
import SwiftUI

enum ScrubState: Equatable {
    case sliding, landed, cancelled
}

final class ScrubModel: ObservableObject {
    @Published var title = ""
    @Published var icon: NSImage?
    @Published var duration: Double = 1
    /// Where the video would be without the scrub (it moves along while the video plays).
    @Published var reference: Double = 0
    @Published var target: Double = 0
    @Published var live = true
    @Published var fine = false
    @Published var state = ScrubState.sliding
}

final class ScrubHUD {
    static let shared = ScrubHUD()
    let model = ScrubModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    /// Bumped by every `show`, so a fade-out that ends late can't hide the next scrub's panel.
    private var showings = 0
    private static let size = NSSize(width: 440, height: 108)
    /// Width of the timeline bar, for deciding when a change is big enough to draw.
    private static let barWidth = 408.0

    func show(media: NowPlaying, at position: Double, live: Bool) {
        hideWork?.cancel()
        hideWork = nil
        showings += 1
        model.title = media.title.isEmpty ? (media.artist.isEmpty ? "Now Playing" : media.artist) : media.title
        model.icon = media.pid > 0 ? NSRunningApplication(processIdentifier: media.pid)?.icon : nil
        model.duration = max(media.duration, 1)
        model.reference = position
        model.target = position
        model.live = live
        model.fine = false
        model.state = .sliding
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Called for every touch frame, so SwiftUI only hears about changes it would draw: a new
    /// second on the clock or half a point on the bar.
    func update(target: Double, reference: Double, fine: Bool) {
        if visiblyDifferent(target, model.target) { model.target = target }
        if visiblyDifferent(reference, model.reference) { model.reference = reference }
        if model.fine != fine { model.fine = fine }
    }

    func finish(_ state: ScrubState, at position: Double) {
        model.state = state
        model.target = position
        if state == .cancelled { model.reference = position }
        let showing = showings
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                if self?.showings == showing { panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (state == .cancelled ? 0.5 : 0.7), execute: work)
    }

    private func visiblyDifferent(_ a: Double, _ b: Double) -> Bool {
        Int(a.rounded()) != Int(b.rounded()) || abs(a - b) / model.duration * Self.barWidth >= 0.5
    }

    private func makePanel() -> NSPanel {
        let frame = NSRect(origin: .zero, size: Self.size)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // A real blur of what's behind. "Active" because EdgePal is never the frontmost app, and
        // an inactive blur draws as flat grey.
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.maskImage = Self.roundedMask(radius: 18)
        let host = NSHostingView(rootView: ScrubView(model: model))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        panel.contentView = blur
        return panel
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        // Above a video's own controls and subtitles, below the middle of the picture.
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                     y: frame.minY + max(64, frame.height * 0.1)))
        panel.invalidateShadow()
    }
}

extension ScrubHUD {
    /// `EdgePal --hud-snapshot <file.png>`: draws the panel mid-scrub, off-screen, so its layout
    /// can be checked (and shown in the README) without a finger on the trackpad.
    @MainActor
    static func snapshot(to url: URL) -> Bool {
        let model = ScrubModel()
        model.title = "A long video with a title that doesn't fit in the panel at all"
        model.icon = NSWorkspace.shared.icon(forFile: "/System/Applications/QuickTime Player.app")
        model.duration = 1106
        model.reference = 300
        model.target = 365
        let view = ScrubView(model: model)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

func formatTime(_ seconds: Double) -> String {
    let s = Int(max(0, seconds).rounded())
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

private struct ScrubView: View {
    @ObservedObject var model: ScrubModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let icon = model.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(.secondary)
                }
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(delta)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            TimelineBar(duration: model.duration, reference: model.reference, target: model.target,
                        dimmed: model.state == .cancelled)
                .frame(height: 14)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(formatTime(model.target))
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                Text("/ " + formatTime(model.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 440, height: 108)
        .environment(\.colorScheme, .dark)
    }

    private var delta: String {
        let d = model.target - model.reference
        return abs(d) < 0.5 ? "" : (d > 0 ? "+" : "−") + formatTime(abs(d))
    }

    private var hint: String {
        switch model.state {
        case .cancelled: return "Cancelled"
        case .landed: return "Done"
        case .sliding:
            let text = model.live ? "Let go to keep it · slide up to undo" : "Let go to jump · slide up to cancel"
            return model.fine ? "Fine · " + text : text
        }
    }
}

private struct TimelineBar: View {
    var duration: Double
    var reference: Double
    var target: Double
    var dimmed: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let referenceX = w * fraction(reference)
            let targetX = w * fraction(target)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height: 5)
                Capsule().fill(.white.opacity(dimmed ? 0.4 : 0.9)).frame(width: max(5, targetX), height: 5)
                Capsule().fill(.white.opacity(0.55)).frame(width: 2, height: 14).offset(x: referenceX - 1)
                Circle().fill(.white).frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .offset(x: targetX - 6)
            }
            .frame(height: geo.size.height)
        }
    }

    private func fraction(_ value: Double) -> Double {
        min(max(value / max(duration, 1), 0), 1)
    }
}
