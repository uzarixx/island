import AppKit
import SwiftUI

struct MessageView: View {
    let icon: String
    let text: String
    let action: String?
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(text)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .multilineTextAlignment(.center)

            if let action {
                Button(action: perform) {
                    Text(action)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .notchGlass(in: Capsule(), tint: Color.notchGreen, interactive: true)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }
}

/// Shrinks a little while pressed, with a springy release.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.1))
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct EqualizerView: View {
    let isAnimating: Bool
    /// A gradient from the album cover; Spotify green without one.
    var colors: [Color]? = nil

    @AppStorage(AppSettings.liveEqualizerKey) private var isLive = false

    /// Six thin bars, like the iPhone's.
    private static let size = CGSize(width: 20, height: 14)
    private static let barWidth: CGFloat = 2
    private static let barSpacing: CGFloat = 1.6

    /// Where a gradient from the bottom-left corner at exactly 45° ends, so it covers the whole
    /// frame: unit points are relative to a non-square frame, so `.topTrailing` would be flatter.
    private static let gradientEnd: UnitPoint = {
        let span = size.width + size.height
        return UnitPoint(x: span / 2 / size.width, y: 1 - span / 2 / size.height)
    }()

    var body: some View {
        // One gradient across all the bars, cut out by them, rising at 45°.
        LinearGradient(colors: colors ?? [Color.notchGreen], startPoint: .bottomLeading, endPoint: Self.gradientEnd)
            .animation(.easeInOut(duration: 0.5), value: colors)
            .mask {
                if isLive {
                    liveBars
                } else {
                    madeUpBars
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
    }

    /// A made-up dance, a few steps a second eased into each other.
    private var madeUpBars: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            bars((0..<AudioLevelMeter.bandCount).map { index in
                let i = Double(index)
                return isAnimating ? 0.3 + 0.7 * abs(sin(t * (2.3 + i * 0.9) + i * 1.7)) : 0.25
            })
            .animation(.easeInOut(duration: 0.12), value: t)
        }
    }

    /// Spotify's real sound, redrawn every display frame with each bar computed for that moment
    /// (the meter eases the levels), so nothing animates in between. Until the meter hears
    /// something, e.g. before the permission is given, a smooth version of the made-up dance.
    private var liveBars: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isAnimating)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let live = isAnimating ? AudioLevelMeter.shared.levels(at: context.date) : nil
            bars((0..<AudioLevelMeter.bandCount).map { index in
                let i = Double(index)
                if let live { return 0.2 + 0.8 * Double(live[index]) }
                guard isAnimating else { return 0.25 }
                // |sin| has a kink at every zero; this is the same wave, smooth.
                return 0.3 + 0.7 * (0.5 - 0.5 * cos(2 * (t * (2.3 + i * 0.9) + i * 1.7)))
            })
        }
    }

    /// Bars with heights 0...1 of the frame.
    private func bars(_ levels: [Double]) -> some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .frame(width: Self.barWidth, height: Self.size.height * levels[index])
            }
        }
        .frame(height: Self.size.height)
    }
}

/// A colored circle with initials, for chats and for links without a site icon.
struct InitialsAvatar: View {
    let name: String
    let size: CGFloat

    private static let palette: [(Color, Color)] = [
        (.pink, .orange), (.blue, .cyan), (.purple, .indigo),
        (.green, .mint), (.orange, .yellow), (.teal, .blue),
    ]

    var body: some View {
        let colors = Self.palette[abs(stableHash) % Self.palette.count]
        Circle()
            .fill(LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// `hashValue` is randomized per launch; this keeps a chat's color stable.
    private var stableHash: Int {
        name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
    }
}
