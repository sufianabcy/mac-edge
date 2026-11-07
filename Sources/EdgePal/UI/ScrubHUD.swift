// EdgePal: the little panel that previews where a video will jump while you slide.
import AppKit
import SwiftUI

final class ScrubModel: ObservableObject {
    @Published var title = ""
    @Published var duration: Double = 1
    @Published var start: Double = 0
    @Published var target: Double = 0
    @Published var cancelled = false
}

final class ScrubHUD {
    static let shared = ScrubHUD()
    let model = ScrubModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, duration: Double, start: Double) {
        hideWork?.cancel()
        model.title = title
        model.duration = max(duration, 1)
        model.start = start
        model.target = start
        model.cancelled = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func update(target: Double) {
        model.target = target
    }

    func hide(cancelled: Bool) {
        model.cancelled = cancelled
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (cancelled ? 0.25 : 0.6), execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 92),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: ScrubView(model: model))
        return panel
    }

    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 60))
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
            HStack {
                Image(systemName: model.cancelled ? "xmark.circle" : "arrow.left.and.right")
                    .foregroundStyle(.secondary)
                Text(model.title.isEmpty ? "Now Playing" : model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                let delta = model.target - model.start
                Text((delta >= 0 ? "+" : "−") + formatTime(abs(delta)))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: max(6, w * model.target / model.duration))
                    Rectangle().fill(.white.opacity(0.5))
                        .frame(width: 2, height: 14)
                        .offset(x: w * model.start / model.duration - 1)
                }
            }
            .frame(height: 6)
            HStack {
                Text(model.cancelled ? "Cancelled" : formatTime(model.target))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                Spacer()
                Text(model.cancelled ? "" : "Let go to jump here")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatTime(model.duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 420, height: 92)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}
