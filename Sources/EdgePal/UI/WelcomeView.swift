// EdgePal: the first-run guide. Explains the edges, gets Accessibility, then lets you try it.
import SwiftUI

struct WelcomeView: View {
    var onDone: () -> Void
    @State private var step = 0
    @StateObject private var permission = PermissionModel()
    @ObservedObject private var engine = EdgeEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: intro
                case 1: access
                default: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0 ..< 3) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Button(step == 2 ? "Done" : "Continue") {
                    if step == 2 {
                        Settings.shared.finishedWelcome = true
                        onDone()
                    } else {
                        step += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
    }

    private var intro: some View {
        VStack(spacing: 18) {
            Text("Your trackpad has four edges you've never used")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            TrackpadPreview(live: false)
                .frame(height: 170)
            VStack(alignment: .leading, spacing: 8) {
                row("speaker.wave.2", "Right edge", "slide for volume")
                row("sun.max", "Left edge", "slide for brightness")
                row("play.rectangle", "Bottom edge", "scrub the video or song that's playing")
                row("square.grid.2x2", "Top corners", "click 1–4 times for your shortcuts")
            }
            Text("Press an edge until the trackpad clicks, then slide. The middle of the trackpad works exactly as before.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var access: some View {
        VStack(spacing: 20) {
            Image(systemName: permission.trusted ? "checkmark.seal.fill" : "hand.raised.fill")
                .font(.system(size: 48))
                .foregroundStyle(permission.trusted ? .green : .accentColor)
            Text(permission.trusted ? "All set" : "One permission")
                .font(.title2.bold())
            Text("EdgePal needs Accessibility to press the volume and brightness keys for you and to keep edge clicks out of your apps. It never records what you type, and touches never leave this Mac.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !permission.trusted {
                Button("Open Accessibility Settings") { permission.ask() }
                    .controlSize(.large)
                Text("Turn on EdgePal in the list. This page updates by itself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tryIt: some View {
        VStack(spacing: 14) {
            Text("Try it on your trackpad")
                .font(.title2.bold())
            TrackpadPreview()
                .frame(height: 210)
            Text(engine.tapRunning ? engine.lastAction : "Gestures start once Accessibility is on.")
                .font(.headline.monospacedDigit())
                .foregroundStyle(engine.tapRunning ? Color.primary : Color.orange)
            Text("Change the corners, edge width and more any time in Settings from the menu bar icon.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Color.accentColor)
            Text(title).bold()
            Text(text).foregroundStyle(.secondary)
        }
    }
}
