import SwiftUI

struct PlayerView: View {
    @ObservedObject var spotify: SpotifyController

    var body: some View {
        Group {
            if !spotify.isRunning {
                MessageView(icon: "music.note", text: L("Spotify не запущен", "Spotify isn’t running"), action: L("Открыть Spotify", "Open Spotify")) {
                    spotify.openSpotify()
                }
            } else if spotify.permissionDenied {
                MessageView(
                    icon: "lock.fill",
                    text: L("Нет доступа к управлению Spotify", "No permission to control Spotify"),
                    action: L("Открыть настройки", "Open Settings")
                ) {
                    spotify.openAutomationSettings()
                }
            } else if let track = spotify.track {
                trackView(track)
            } else {
                MessageView(icon: "music.note", text: L("Сейчас ничего не играет", "Nothing is playing"), action: nil, perform: {})
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func trackView(_ track: SpotifyTrack) -> some View {
        HStack(spacing: 16) {
            ArtworkView(image: spotify.artwork, cornerRadius: 14)
                .frame(width: 96, height: 96)
                .scaleEffect(spotify.isPlaying ? 1 : 0.92)
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: spotify.isPlaying)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(track.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    if spotify.canLike {
                        LikeButton(isLiked: spotify.isLiked, action: spotify.toggleLike)
                    } else if spotify.showsLike {
                        LikeButton(isLiked: nil, needsReconnect: true, action: spotify.reconnectForLikes)
                    }
                }

                ProgressSection(spotify: spotify, duration: track.duration)
                    .padding(.top, 4)

                controls
                    .frame(maxWidth: .infinity)

                volumeControl
            }
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 6) {
            Button { spotify.setVolume(spotify.volume == 0 ? 50 : 0) } label: {
                Image(systemName: spotify.volume == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(spotify.volume == 0 ? L("Включить звук", "Unmute") : L("Выключить звук", "Mute"))

            SeekBar(progress: Double(spotify.volume) / 100) { fraction in
                spotify.setVolume(Int((fraction * 100).rounded()))
            }

            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.5))
    }

    private var controls: some View {
        HStack(spacing: 0) {
            ModeButton(systemName: "shuffle", isOn: spotify.isShuffling, help: shuffleHelp) {
                spotify.toggleShuffle()
            }
            .frame(maxWidth: .infinity)
            ControlButton(systemName: "backward.fill", size: 16) { spotify.previousTrack() }
                .frame(maxWidth: .infinity)
            ControlButton(systemName: spotify.isPlaying ? "pause.fill" : "play.fill", size: 18, isProminent: true) {
                spotify.playPause()
            }
            .frame(maxWidth: .infinity)
            ControlButton(systemName: "forward.fill", size: 16) { spotify.nextTrack() }
                .frame(maxWidth: .infinity)
            ModeButton(
                systemName: spotify.repeatMode == .track ? "repeat.1" : "repeat",
                isOn: spotify.repeatMode != .off,
                help: repeatHelp
            ) {
                spotify.cycleRepeatMode()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var shuffleHelp: String {
        spotify.isShuffling ? L("Перемешивание включено", "Shuffle is on") : L("Перемешивать", "Shuffle")
    }

    private var repeatHelp: String {
        switch spotify.repeatMode {
        case .off:
            return L("Повторять плейлист", "Repeat playlist")
        case .context:
            return spotify.canRepeatTrack
                ? L("Повторять трек", "Repeat track")
                : L("Выключить повтор. Повтор трека — переподключи Spotify в настройках", "Turn off repeat. To repeat a track, reconnect Spotify in Settings")
        case .track:
            return L("Выключить повтор", "Turn off repeat")
        }
    }
}

/// Heart like in Spotify: adds the track to "Liked Songs". Dimmed while the state is loading,
/// or when Spotify has to be reconnected for it.
private struct LikeButton: View {
    let isLiked: Bool?
    var needsReconnect = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let liked = isLiked == true
        Button(action: action) {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(liked ? Color.notchGreen : .white.opacity(isLiked == nil ? 0.3 : isHovering ? 0.9 : 0.55))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovering = $0 }
        .help(
            needsReconnect ? L("Чтобы ставить лайки, переподключи Spotify — нажми, откроется браузер", "To like songs, reconnect Spotify — click to open the browser")
                : liked ? L("Убрать из «Любимых треков» (L)", "Remove from Liked Songs (L)") : L("Добавить в «Любимые треки» (L)", "Save to Liked Songs (L)")
        )
        .animation(.easeOut(duration: 0.15), value: liked)
    }
}

/// Shuffle / repeat toggle: green with a dot underneath when on, like in Spotify.
private struct ModeButton: View {
    let systemName: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                Circle()
                    .frame(width: 3, height: 3)
                    .opacity(isOn ? 1 : 0)
            }
            .foregroundStyle(isOn ? Color.notchGreen : .white.opacity(isHovering ? 0.9 : 0.55))
            .frame(width: 28, height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

private struct ProgressSection: View {
    @ObservedObject var spotify: SpotifyController
    let duration: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let position = spotify.position(at: context.date)
            VStack(spacing: 3) {
                SeekBar(progress: duration > 0 ? position / duration : 0) { fraction in
                    spotify.seek(to: fraction * duration)
                }
                HStack {
                    Text(formatTime(position))
                    Spacer()
                    Text("-" + formatTime(max(duration - position, 0)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

private struct SeekBar: View {
    let progress: Double
    let onSeek: (Double) -> Void

    @State private var dragProgress: Double?
    @State private var isHovering = false

    var body: some View {
        GeometryReader { geometry in
            let value = dragProgress ?? progress
            let highlighted = isHovering || dragProgress != nil

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule()
                    .fill(highlighted ? Color.notchGreen : .white)
                    .frame(width: max(0, geometry.size.width * min(max(value, 0), 1)))
            }
            .frame(height: highlighted ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragProgress = clamp(drag.location.x / geometry.size.width)
                    }
                    .onEnded { drag in
                        dragProgress = nil
                        onSeek(clamp(drag.location.x / geometry.size.width))
                    }
            )
            .animation(.easeOut(duration: 0.15), value: highlighted)
        }
        .frame(height: 12)
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

private struct ControlButton: View {
    let systemName: String
    let size: CGFloat
    /// Play/pause always sits on glass; the others get it on hover.
    var isProminent = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            let icon = Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: isProminent ? 38 : 32, height: isProminent ? 38 : 32)
                .contentShape(Circle())
            if isProminent || isHovering {
                icon.notchGlass(in: Circle(), interactive: true, fallback: .white.opacity(0.12))
            } else {
                icon
            }
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovering = $0 }
    }
}

