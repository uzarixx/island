import SwiftUI

/// Laid out like Spotify's queue panel: "Now playing", then "Next in queue".
struct QueueView: View {
    @ObservedObject var queue: QueueController
    @ObservedObject var auth: SpotifyAuth
    @ObservedObject var player: PlayerController
    let openSettings: () -> Void

    var body: some View {
        let items = queue.items
        if items.isEmpty && queue.state == .loaded {
            MessageView(icon: "list.bullet", text: L("Очередь пуста", "Queue is empty"), action: nil, perform: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(items) { item in
                                if item.skips == 0 {
                                    SectionTitle(L("Сейчас играет", "Now playing"))
                                } else if item.skips == 1 {
                                    SectionTitle(L("Далее в очереди", "Next in queue"))
                                        .padding(.top, 4)
                                }
                                QueueRow(track: item, isPlaying: player.isPlaying, colors: player.artworkColors) {
                                    queue.play(item)
                                }
                                .id(item.id)
                            }
                            if queue.state == .loading && queue.upcoming.isEmpty {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 8)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    // A new track starts at the top of the list.
                    .onChange(of: player.track?.id) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(QueueController.currentID, anchor: .top)
                        }
                    }
                }
                footer
            }
        }
    }

    /// The queue itself needs the Web API; the current track works without it.
    @ViewBuilder
    private var footer: some View {
        switch queue.state {
        case .needsSetup:
            FooterHint(text: L("Очередь — через Spotify API", "Queue uses the Spotify API"), action: L("Настроить", "Set up"), perform: openSettings)
        case .signedOut:
            FooterHint(
                text: L("Очередь — через Spotify API", "Queue uses the Spotify API"),
                action: auth.isSigningIn ? L("Ждём браузер…", "Waiting for browser…") : L("Войти", "Sign in"),
                perform: auth.signIn
            )
        case .failed(let message):
            FooterHint(text: message, action: L("Повторить", "Retry")) { queue.reload() }
        case .loading, .loaded:
            EmptyView()
        }
    }
}

private struct SectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
    }
}

private struct FooterHint: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .lineLimit(1)
                .foregroundStyle(.white.opacity(0.45))
            Spacer(minLength: 4)
            Button(action: perform) {
                Text(action)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.notchGreen)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10))
        .padding(.horizontal, 6)
    }
}

/// The playing track sits on glass; other rows only light up on hover.
private struct RowBackground: ViewModifier {
    let isCurrent: Bool
    let isHovering: Bool

    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    func body(content: Content) -> some View {
        if isCurrent {
            content.notchGlass(in: shape, fallback: .white.opacity(0.06))
        } else {
            content.background(shape.fill(.white.opacity(isHovering ? 0.1 : 0)))
        }
    }
}

private struct QueueRow: View {
    let track: QueueTrack
    let isPlaying: Bool
    let colors: [Color]?
    let action: () -> Void

    @State private var isHovering = false

    private var isCurrent: Bool { track.skips == 0 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AsyncImage(url: track.artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.white.opacity(0.1))
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isCurrent ? Color.notchGreen : .white)
                    Text(track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .lineLimit(1)

                Spacer(minLength: 4)

                if isCurrent {
                    EqualizerView(isAnimating: isPlaying, colors: colors)
                        .scaleEffect(0.75)
                } else {
                    Text(formatTime(track.duration))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .modifier(RowBackground(isCurrent: isCurrent, isHovering: isHovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .onHover { isHovering = $0 }
    }
}
