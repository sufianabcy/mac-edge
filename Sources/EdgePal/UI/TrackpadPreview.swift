// EdgePal: a live picture of the trackpad, its edge strips and your fingers.
import SwiftUI

final class PreviewModel: ObservableObject {
    @Published var width = 160.0
    @Published var height = 100.0
    @Published var fingers: [Finger] = []

    func attach() {
        EdgeEngine.shared.previewHandler = { [weak self] frame in
            guard let self else { return }
            if self.width != frame.widthMM { self.width = frame.widthMM }
            if self.height != frame.heightMM { self.height = frame.heightMM }
            self.fingers = frame.fingers.filter { $0.state >= 2 && $0.state <= 5 }
        }
    }

    func detach() {
        EdgeEngine.shared.previewHandler = nil
    }
}

struct TrackpadPreview: View {
    @StateObject private var model = PreviewModel()
    @ObservedObject private var settings = Settings.shared
    var live = true

    var body: some View {
        let layout = ZoneLayout(width: model.width, height: model.height, edgeShare: settings.edgeWidth)
        let active = Set(model.fingers.filter(\.isDown).compactMap { layout.zones(x: $0.x, y: $0.y).first })
        GeometryReader { geo in
            let scale = min(geo.size.width / layout.width, geo.size.height / layout.height)
            let w = layout.width * scale, h = layout.height * scale, e = layout.edge * scale
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14 * scale / 2, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 14 * scale / 2, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15)))
                    .frame(width: w, height: h)

                strip(.left, label: sideLabel(left: true), active: active)
                    .frame(width: e, height: h - e).offset(x: 0, y: 0)
                strip(.right, label: sideLabel(left: false), active: active)
                    .frame(width: e, height: h - e).offset(x: w - e, y: 0)
                strip(.bottom, label: settings.timelineEdge ? "Timeline" : "Off", active: active)
                    .frame(width: w, height: e).offset(x: 0, y: h - e)
                strip(.topLeft, label: cornerLabel(.topLeft), active: active, corner: true)
                    .frame(width: e, height: e).offset(x: 0, y: 0)
                strip(.topRight, label: cornerLabel(.topRight), active: active, corner: true)
                    .frame(width: e, height: e).offset(x: w - e, y: 0)

                ForEach(model.fingers, id: \.id) { f in
                    Circle()
                        .fill(f.isDown ? Color.accentColor : Color.secondary.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .offset(x: f.x * scale - 9, y: h - f.y * scale - 9)
                }
            }
            .frame(width: w, height: h)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(model.width / model.height, contentMode: .fit)
        .onAppear { if live { model.attach() } }
        .onDisappear { model.detach() }
    }

    private func strip(_ zone: Zone, label: String, active: Set<Zone>, corner: Bool = false) -> some View {
        let lit = active.contains(zone)
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(lit ? Color.accentColor.opacity(0.45) : Color.accentColor.opacity(corner ? 0.18 : 0.10))
            .overlay(
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(2)
                    .rotationEffect(zone == .left ? .degrees(-90) : zone == .right ? .degrees(90) : .zero)
                    .fixedSize(horizontal: zone == .left || zone == .right, vertical: false)
            )
    }

    private func sideLabel(left: Bool) -> String {
        let volume = left == settings.swapSides
        if volume { return settings.volumeEdge ? "Volume" : "Off" }
        return settings.brightnessEdge ? "Brightness" : "Off"
    }

    private func cornerLabel(_ corner: Corner) -> String {
        guard settings.cornersEnabled, let first = settings.actions(for: corner).first(where: \.isSet) else { return "" }
        return first.kind == .keyCombo && !first.keyLabel.isEmpty ? first.keyLabel : first.kind.title
    }
}
