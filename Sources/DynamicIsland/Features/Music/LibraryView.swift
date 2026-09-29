import SwiftUI

enum MusicPane: String, CaseIterable {
    case queue, playlists, search

    var title: String {
        switch self {
        case .queue: L("Очередь", "Queue")
        case .playlists: L("Плейлисты", "Playlists")
        case .search: L("Поиск", "Search")
        }
    }

    static let defaultsKey = "musicPane"
}

/// The right side of the music tab: the queue, the user's playlists, or Spotify search.
struct MusicBrowserView: View {
    @ObservedObject var queue: QueueController
    @ObservedObject var library: LibraryController
    @ObservedObject var player: PlayerController
    /// Shared with the notch: typing in a search field keeps it open and takes the keyboard.
    @Binding var isEditing: Bool
    let openSettings: () -> Void

    @AppStorage(MusicPane.defaultsKey) private var pane = MusicPane.queue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotchSegmented(options: MusicPane.allCases, title: \.title, selection: $pane)
                .frame(maxWidth: .infinity)

            switch pane {
            case .queue:
                QueueView(queue: queue, auth: queue.auth, player: player, openSettings: openSettings)
            case .playlists:
                PlaylistsPane(library: library, auth: library.auth, player: player, isEditing: $isEditing, openSettings: openSettings)
            case .search:
                SearchPane(library: library, auth: library.auth, player: player, isEditing: $isEditing, openSettings: openSettings) { playlist in
                    library.open(playlist)
                    pane = .playlists
                }
            }

            if let notice = library.notice {
                Text(notice)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.notchGreen)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: library.notice)
        // A field left behind on another pane mustn't keep the notch pinned.
        .onChange(of: pane) { isEditing = false }
    }
}

// MARK: - Playlists

private struct PlaylistsPane: View {
    @ObservedObject var library: LibraryController
    @ObservedObject var auth: SpotifyAuth
    @ObservedObject var player: PlayerController
    @Binding var isEditing: Bool
    let openSettings: () -> Void

    @State private var filter = ""

    private var filtered: [LibraryItem] {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return library.playlists }
        return library.playlists.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        Group {
            if let problem = AccessProblem(auth: auth, needsPlaylists: true) {
                AccessProblemView(problem: problem, auth: auth, openSettings: openSettings)
            } else if let playlist = library.openedPlaylist {
                PlaylistDetail(playlist: playlist, library: library, player: player, isEditing: $isEditing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 6) {
                    if library.playlists.count > 8 {
                        MusicSearchField(placeholder: L("Найти среди \(library.playlists.count) плейлистов", "Search \(library.playlists.count) playlists"), text: $filter, isEditing: $isEditing)
                    }
                    content
                }
            }
        }
        .onAppear(perform: library.loadPlaylistsIfNeeded)
    }

    @ViewBuilder
    private var content: some View {
        switch library.playlistsState {
        case .idle:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where library.playlists.isEmpty:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where library.playlists.isEmpty:
            MessageView(icon: "exclamationmark.triangle", text: message, action: L("Повторить", "Retry"), perform: library.loadPlaylists)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            if filtered.isEmpty {
                Text(filter.isEmpty ? L("Плейлистов пока нет", "No playlists yet") : L("Ничего не нашлось", "No results"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { item in
                            LibraryRow(
                                item: item,
                                isPlayingContext: library.playingContext == item.uri,
                                isPlaying: player.isPlaying,
                                colors: player.artworkColors,
                                play: { library.play(item) },
                                open: { withAnimation(.spring(duration: 0.35)) { library.open(item) } }
                            )
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

/// A playlist's songs: pick one and the playlist plays on from it.
private struct PlaylistDetail: View {
    let playlist: LibraryItem
    @ObservedObject var library: LibraryController
    @ObservedObject var player: PlayerController
    @Binding var isEditing: Bool

    @State private var filter = ""

    private var tracks: [LibraryItem] {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return library.playlistTracks }
        return library.playlistTracks.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.subtitle.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            if library.playlistTracks.count > 12 || !filter.isEmpty {
                MusicSearchField(placeholder: L("Найти песню в плейлисте", "Search in playlist"), text: $filter, isEditing: $isEditing)
            }
            content
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                isEditing = false
                withAnimation(.spring(duration: 0.35)) { library.closePlaylist() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.1)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(L("К плейлистам", "Back to playlists"))

            LibraryArtwork(item: playlist)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(playlist.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                library.play(playlist)
            } label: {
                Label(L("Включить", "Play"), systemImage: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.notchGreen))
            }
            .buttonStyle(PressableButtonStyle())
            .help(L("Включить плейлист с начала", "Play playlist from the start"))
        }
    }

    @ViewBuilder
    private var content: some View {
        if library.playlistTracks.isEmpty {
            switch library.tracksState {
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                Text(L("В плейлисте пока нет песен", "No songs in this playlist yet"))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(tracks) { track in
                        LibraryRow(
                            item: track,
                            isPlayingContext: player.track?.id == track.uri && library.playingContext == playlist.uri,
                            isPlaying: player.isPlaying,
                            colors: player.artworkColors,
                            play: { library.playTrack(track) },
                            addToQueue: { library.addToQueue(track) }
                        )
                        .opacity(track.isPlayable ? 1 : 0.4)
                        .onAppear {
                            // Reaching the end loads the next page.
                            if filter.isEmpty, track.id == library.playlistTracks.last?.id { library.loadMoreTracks() }
                        }
                    }
                    if library.hasMoreTracks || library.tracksState == .loading {
                        ProgressView().controlSize(.small).padding(.vertical, 6)
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Search

private struct SearchPane: View {
    @ObservedObject var library: LibraryController
    @ObservedObject var auth: SpotifyAuth
    @ObservedObject var player: PlayerController
    @Binding var isEditing: Bool
    let openSettings: () -> Void
    let openPlaylist: (LibraryItem) -> Void

    var body: some View {
        if let problem = AccessProblem(auth: auth, needsPlaylists: false) {
            AccessProblemView(problem: problem, auth: auth, openSettings: openSettings)
        } else {
            VStack(spacing: 6) {
                MusicSearchField(
                    placeholder: L("Трек, исполнитель, альбом, плейлист", "Songs, artists, albums, playlists"),
                    text: $library.query,
                    isEditing: $isEditing,
                    isLoading: library.searchState == .loading,
                    focusOnAppear: true
                )
                results
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        let results = library.results
        switch library.searchState {
        case .idle:
            VStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20))
                Text(L("Клик по результату — сразу включит", "Click a result to play it"))
                    .font(.system(size: 11))
            }
            .foregroundStyle(.white.opacity(0.4))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded where results.isEmpty:
            Text(L("Ничего не нашлось", "No results"))
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    section(L("Треки", "Songs"), results.tracks)
                    section(L("Исполнители", "Artists"), Array(results.artists.prefix(4)))
                    section(L("Альбомы", "Albums"), Array(results.albums.prefix(5)))
                    section(L("Плейлисты", "Playlists"), Array(results.playlists.prefix(5)))
                }
            }
            .scrollIndicators(.never)
            .opacity(library.searchState == .loading ? 0.5 : 1)
            .animation(.easeOut(duration: 0.15), value: library.searchState)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [LibraryItem]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 6)
                .padding(.top, 4)
            ForEach(items) { item in
                LibraryRow(
                    item: item,
                    isPlayingContext: library.playingContext == item.uri || player.track?.id == item.uri,
                    isPlaying: player.isPlaying,
                    colors: player.artworkColors,
                    play: { library.play(item) },
                    open: item.kind == .playlist ? { openPlaylist(item) } : nil,
                    addToQueue: item.kind == .track ? { library.addToQueue(item) } : nil
                )
            }
        }
    }
}

// MARK: - Pieces

/// A search field in the notch; clicking it takes the keyboard, Esc clears it, then leaves it.
private struct MusicSearchField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isEditing: Bool
    var isLoading = false
    var focusOnAppear = false

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(.white.opacity(0.35)))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($isFocused)
                .onExitCommand {
                    if text.isEmpty { isEditing = false } else { text = "" }
                }
            if isLoading {
                ProgressView().controlSize(.mini)
            } else if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .notchGlass(in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { isFocused = true }
        .onChange(of: isFocused) { if isFocused { isEditing = true } }
        .onChange(of: isEditing) {
            if !isEditing {
                isFocused = false
            } else if focusOnAppear {
                // Opened with the keyboard shortcut or "/": type right away.
                DispatchQueue.main.async { isFocused = true }
            }
        }
        .onAppear {
            // Only when the keyboard is already in the notch; a hover mustn't pin it open.
            if focusOnAppear && isEditing { DispatchQueue.main.async { isFocused = true } }
        }
    }
}

private struct LibraryRow: View {
    let item: LibraryItem
    /// Playback is coming from this playlist or album, or this is the track playing.
    let isPlayingContext: Bool
    let isPlaying: Bool
    let colors: [Color]?
    let play: () -> Void
    /// Playlists open to show their songs; the play button still plays them whole.
    var open: (() -> Void)? = nil
    var addToQueue: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            LibraryArtwork(item: item)
                .frame(width: 30, height: 30)
                .clipShape(item.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous)))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isPlayingContext ? Color.notchGreen : .white)
                Text(item.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .lineLimit(1)

            Spacer(minLength: 4)

            if isHovering {
                if let addToQueue {
                    RowButton(icon: "text.line.last.and.arrowtriangle.forward", help: L("Добавить в очередь", "Add to queue"), action: addToQueue)
                }
                RowButton(icon: "play.fill", help: open == nil ? L("Включить", "Play") : L("Включить весь плейлист", "Play whole playlist"), action: play)
            } else if isPlayingContext {
                EqualizerView(isAnimating: isPlaying, colors: colors)
                    .scaleEffect(0.75)
            } else if let duration = item.duration {
                Text(formatTime(duration))
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            if open != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(isHovering ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open ?? play)
        .onHover { isHovering = $0 }
        .help(open == nil ? item.title : L("Открыть «\(item.title)»", "Open “\(item.title)”"))
    }
}

/// A cover; Liked Songs gets Spotify's purple heart.
private struct LibraryArtwork: View {
    let item: LibraryItem

    var body: some View {
        artwork
            .clipShape(item.kind == .artist ? AnyShape(Circle()) : AnyShape(Rectangle()))
    }

    @ViewBuilder
    private var artwork: some View {
        if item.kind == .likedSongs {
            LinearGradient(colors: [Color(red: 0.27, green: 0.18, blue: 0.9), Color(red: 0.55, green: 0.85, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(.white))
        } else {
            AsyncImage(url: item.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.white.opacity(0.1))
                    .overlay(Image(systemName: placeholderIcon).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)))
            }
        }
    }

    private var placeholderIcon: String {
        switch item.kind {
        case .artist: "person.fill"
        case .album: "square.stack"
        case .track: "music.note"
        case .playlist, .likedSongs: "music.note.list"
        }
    }
}

private struct RowButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(isHovering ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// Why the Web API panes can't show anything yet.
private enum AccessProblem {
    case needsSetup, signedOut, needsReconnect

    @MainActor
    init?(auth: SpotifyAuth, needsPlaylists: Bool) {
        if !auth.hasClientID {
            self = .needsSetup
        } else if !auth.isSignedIn {
            self = .signedOut
        } else if needsPlaylists && !auth.canReadPlaylists {
            self = .needsReconnect
        } else {
            return nil
        }
    }
}

private struct AccessProblemView: View {
    let problem: AccessProblem
    @ObservedObject var auth: SpotifyAuth
    let openSettings: () -> Void

    var body: some View {
        Group {
            switch problem {
            case .needsSetup:
                MessageView(icon: "music.note.list", text: L("Плейлисты и поиск — через Spotify API", "Playlists and search use the Spotify API"), action: L("Настроить", "Set up"), perform: openSettings)
            case .signedOut:
                MessageView(icon: "music.note.list", text: L("Плейлисты и поиск — через Spotify API", "Playlists and search use the Spotify API"), action: auth.isSigningIn ? L("Ждём браузер…", "Waiting for browser…") : L("Войти", "Sign in"), perform: auth.signIn)
            case .needsReconnect:
                MessageView(icon: "music.note.list", text: L("Чтобы видеть плейлисты, переподключи Spotify", "Reconnect Spotify to see your playlists"), action: L("Переподключить", "Reconnect")) {
                    auth.signOut()
                    auth.signIn()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
