import SwiftUI

/// Compact state: something on each side of the camera, like the iPhone's Dynamic Island.
struct CollapsedActivityView: View {
    let activity: CollapsedActivity
    @ObservedObject var spotify: SpotifyController
    let sideWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: sideWidth)
            Spacer(minLength: 0)
            trailing.frame(width: sideWidth)
        }
    }

    @ViewBuilder
    private var leading: some View {
        switch activity {
        case .music:
            ArtworkView(image: spotify.artwork, cornerRadius: 4)
                .frame(width: 18, height: 18)
        case .battery(let event):
            BatteryGlyph(event: event)
        case .recording:
            RecordingDot()
        case .pickedColor(let picked):
            Circle()
                .fill(picked.color)
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity {
        case .music:
            EqualizerView(isAnimating: spotify.isPlaying, colors: spotify.artworkColors)
        case .battery(let event):
            BatteryPercent(event: event)
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(formatTime(context.date.timeIntervalSince(since)))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.red)
            }
        case .pickedColor(let picked):
            Text(picked.hex)
                .font(.system(size: 11, weight: .semibold).monospaced())
                .foregroundStyle(.white)
        }
    }
}

extension BatteryEvent {
    /// Green while charging; red when the battery runs low.
    var color: Color {
        switch self {
        case .pluggedIn: .green
        case .low: .red
        }
    }
}

/// A battery that fills up to the charge level when it appears, with a bolt while charging.
struct BatteryGlyph: View {
    let event: BatteryEvent

    @State private var progress: CGFloat = 0

    var body: some View {
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(event.color)
                    .frame(width: max(2, 20 * progress * CGFloat(event.status.level) / 100), height: 8)
                    .padding(.leading, 2)
            }
            .frame(width: 24, height: 12)
            .overlay {
                if case .pluggedIn = event {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            Capsule()
                .fill(.white.opacity(0.45))
                .frame(width: 1.5, height: 4)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.9).delay(0.15)) { progress = 1 }
        }
    }
}

struct BatteryPercent: View {
    let event: BatteryEvent

    var body: some View {
        Text("\(event.status.level)%")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(event.color)
    }
}

private struct RecordingDot: View {
    @State private var isDim = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .opacity(isDim ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
    }
}

struct VolumeIndicator: View {
    let volume: Int
    let colors: [Color]?

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 22, height: 3)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: colors ?? [Color.notchGreen], startPoint: .leading, endPoint: .trailing))
                        .frame(width: 22 * CGFloat(volume) / 100)
                }
                .animation(.easeOut(duration: 0.1), value: volume)
        }
    }
}
