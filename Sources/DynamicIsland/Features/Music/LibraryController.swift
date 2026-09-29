import Combine
import Foundation

/// Something in the music tab's lists that can be played: a playlist, album, artist or track.
struct LibraryItem: Identifiable, Equatable {
    enum Kind {
        case likedSongs, playlist, album, artist, track
    }

    let kind: Kind
    let uri: String
    let title: String
    /// "42 трека · Андрей", an artist, an album.
    let subtitle: String
    let artworkURL: URL?
    /// For tracks: the album they're on, so playback goes on through it.
    var context: String? = nil
    var duration: Double? = nil
    /// Place in a playlist: the same song can be in it twice.
    var position: Int? = nil

    var id: String { position.map { "\($0):\(uri)" } ?? uri }

    /// Local files and removed songs can't be played from here.
    var isPlayable: Bool { !uri.hasPrefix("spotify:local:") }
}

/// The user's playlists and Spotify search, via the Web API. Playing goes through
/// `PlayerController` (AppleScript), which works without Premium.
@MainActor
final class LibraryController: ObservableObject {
    enum State: Equatable {
        case idle, loading, loaded, failed(String)
    }

    @Published private(set) var playlists: [LibraryItem] = []
    @Published private(set) var playlistsState: State = .idle
    @Published var query = "" {
        didSet { scheduleSearch() }
    }
    @Published private(set) var results = SearchResults()
    @Published private(set) var searchState: State = .idle
    /// The playlist, album or artist playback is coming from, to mark it in the lists.
    @Published private(set) var playingContext: String?
    /// "Добавлено в очередь" / an error, shown for a moment.
    @Published private(set) var notice: String?

    /// The playlist whose songs are shown in the notch; nil for the list of playlists.
    @Published private(set) var openedPlaylist: LibraryItem?
    @Published private(set) var playlistTracks: [LibraryItem] = []
    @Published private(set) var tracksState: State = .idle
    private var nextTracksPage: URL?
    private var tracksTask: Task<Void, Never>?

    struct SearchResults: Equatable {
        var tracks: [LibraryItem] = []
        var artists: [LibraryItem] = []
        var albums: [LibraryItem] = []
        var playlists: [LibraryItem] = []

        var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty }
    }

    let auth: SpotifyAuth
    private let player: PlayerController
    private let api: SpotifyWebAPI
    private var searchTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var playlistsLoadedAt: Date?
    private var cancellables = Set<AnyCancellable>()

    init(auth: SpotifyAuth, player: PlayerController) {
        self.auth = auth
        self.player = player
        api = SpotifyWebAPI(auth: auth)

        auth.$isSignedIn
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.playlists = []
                self?.playlistsLoadedAt = nil
                self?.playlistsState = .idle
            }
            .store(in: &cancellables)

        // A new track may come from a different playlist.
        player.$track
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshPlayingContext() }
            .store(in: &cancellables)
    }

    var canBrowse: Bool { auth.isSignedIn }

    // MARK: - Playlists

    /// Loads the playlists the first time and again after a few minutes; cheap to call often.
    func loadPlaylistsIfNeeded() {
        guard auth.isSignedIn, auth.canReadPlaylists, playlistsState != .loading else { return }
        if let loadedAt = playlistsLoadedAt, Date().timeIntervalSince(loadedAt) < 5 * 60 { return }
        loadPlaylists()
    }

    func loadPlaylists() {
        guard auth.isSignedIn else { return }
        if playlists.isEmpty { playlistsState = .loading }
        Task {
            do {
                async let fetched = api.playlists()
                async let user = try? api.currentUser()
                async let likedCount = try? api.likedSongsCount()
                let (items, me, liked) = try await (fetched, user, likedCount)

                var list: [LibraryItem] = []
                if let me {
                    // Liked Songs isn't a playlist in the API, but it plays like one.
                    list.append(LibraryItem(
                        kind: .likedSongs,
                        uri: "spotify:user:\(me.id):collection",
                        title: L("Любимые треки", "Liked Songs"),
                        subtitle: liked.map(Self.trackCount) ?? L("Плейлист", "Playlist"),
                        artworkURL: nil
                    ))
                }
                list += items.map { playlist in
                    let owner = playlist.owner?.id == me?.id ? nil : playlist.owner?.displayName
                    return LibraryItem(
                        kind: .playlist,
                        uri: playlist.uri,
                        title: playlist.name,
                        subtitle: [playlist.trackCount.map(Self.trackCount), owner].compactMap { $0 }.joined(separator: " · "),
                        artworkURL: playlist.images?.thumbnailURL()
                    )
                }
                playlists = list
                playlistsLoadedAt = Date()
                playlistsState = .loaded
            } catch {
                playlistsState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Playlist contents

    /// Shows a playlist's songs to pick one from.
    func open(_ playlist: LibraryItem) {
        openedPlaylist = playlist
        playlistTracks = []
        nextTracksPage = nil
        tracksState = .loading
        tracksTask?.cancel()
        tracksTask = Task {
            do {
                let page = playlist.kind == .likedSongs
                    ? try await api.likedTracks()
                    : try await api.playlistTracks(id: Self.playlistID(of: playlist.uri))
                guard !Task.isCancelled else { return }
                append(page, to: playlist)
            } catch is CancellationError {
            } catch SpotifyAPIError.http(403, _), SpotifyAPIError.http(404, _) {
                guard !Task.isCancelled else { return }
                tracksState = .failed(L("Spotify не показывает песни этого плейлиста, но его можно включить целиком", "Spotify doesn’t show this playlist’s songs, but you can play it as a whole"))
            } catch {
                guard !Task.isCancelled else { return }
                tracksState = .failed(error.localizedDescription)
            }
        }
    }

    func closePlaylist() {
        tracksTask?.cancel()
        openedPlaylist = nil
        playlistTracks = []
        nextTracksPage = nil
        tracksState = .idle
    }

    /// The next page, when the list is scrolled to its end.
    func loadMoreTracks() {
        guard let next = nextTracksPage, let playlist = openedPlaylist, tracksState != .loading else { return }
        tracksState = .loading
        nextTracksPage = nil
        tracksTask = Task {
            guard let page = try? await api.trackPage(next), !Task.isCancelled, openedPlaylist == playlist else {
                tracksState = .loaded
                return
            }
            append(page, to: playlist)
        }
    }

    /// Plays a song of the opened playlist; the playlist goes on after it.
    func playTrack(_ track: LibraryItem) {
        guard let playlist = openedPlaylist, track.isPlayable else { return }
        player.play(track.uri, context: playlist.uri)
        playingContext = playlist.uri
    }

    var hasMoreTracks: Bool { nextTracksPage != nil }

    private func append(_ page: (tracks: [APITrack], next: URL?), to playlist: LibraryItem) {
        let start = playlistTracks.count
        playlistTracks += page.tracks.enumerated().map { offset, track in
            LibraryItem(
                kind: .track,
                uri: track.uri,
                title: track.name,
                subtitle: track.artistLine,
                artworkURL: track.thumbnailURL(),
                context: playlist.uri,
                duration: track.durationMs.map { Double($0) / 1000 },
                position: start + offset
            )
        }
        nextTracksPage = page.next
        tracksState = .loaded
    }

    /// "spotify:playlist:37i9d…" → "37i9d…".
    private static func playlistID(of uri: String) -> String {
        uri.split(separator: ":").last.map(String.init) ?? uri
    }

    // MARK: - Playing

    func play(_ item: LibraryItem) {
        player.play(item.uri, context: item.context)
        if item.kind != .track { playingContext = item.uri }
        // Spotify reports the new context once playback has switched.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            refreshPlayingContext()
        }
    }

    func addToQueue(_ item: LibraryItem) {
        Task {
            do {
                try await api.addToQueue(item.uri)
                show(L("Добавлено в очередь", "Added to queue"))
            } catch SpotifyAPIError.http(403, _) {
                show(L("Очередь через API — только с Premium", "Queueing via the API requires Premium"))
            } catch SpotifyAPIError.http(404, _) {
                show(L("Сначала включи музыку в Spotify", "Start playing something in Spotify first"))
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func refreshPlayingContext() {
        guard auth.isSignedIn else { return }
        Task {
            guard let context = try? await api.playbackContext() else { return }
            if context != playingContext { playingContext = context }
        }
    }

    // MARK: - Search

    func clearSearch() {
        query = ""
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = SearchResults()
            searchState = .idle
            return
        }
        guard auth.isSignedIn else { return }
        searchState = .loading
        searchTask = Task {
            // Wait until typing pauses: one request per word, not per letter.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let response = try await api.search(text)
                guard !Task.isCancelled else { return }
                results = Self.results(from: response)
                searchState = .loaded
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                guard !Task.isCancelled else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    private static func results(from response: SearchResponse) -> SearchResults {
        SearchResults(
            tracks: response.tracks.map { track in
                LibraryItem(
                    kind: .track,
                    uri: track.uri,
                    title: track.name,
                    subtitle: track.artistLine,
                    artworkURL: track.thumbnailURL(),
                    context: track.album?.uri,
                    duration: track.durationMs.map { Double($0) / 1000 }
                )
            },
            artists: response.artists.map { artist in
                LibraryItem(kind: .artist, uri: artist.uri, title: artist.name, subtitle: L("Исполнитель", "Artist"), artworkURL: artist.images?.thumbnailURL())
            },
            albums: response.albums.compactMap { album in
                guard let uri = album.uri, let name = album.name else { return nil }
                let artists = album.artists?.map(\.name).joined(separator: ", ") ?? ""
                return LibraryItem(kind: .album, uri: uri, title: name, subtitle: artists.isEmpty ? L("Альбом", "Album") : L("Альбом · \(artists)", "Album · \(artists)"), artworkURL: album.images?.thumbnailURL())
            },
            playlists: response.playlists.map { playlist in
                LibraryItem(
                    kind: .playlist,
                    uri: playlist.uri,
                    title: playlist.name,
                    subtitle: [L("Плейлист", "Playlist"), playlist.owner?.displayName].compactMap { $0 }.joined(separator: " · "),
                    artworkURL: playlist.images?.thumbnailURL()
                )
            }
        )
    }

    // MARK: - Helpers

    private func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }

    /// "1 трек", "3 трека", "12 треков".
    static func trackCount(_ count: Int) -> String {
        plural(count, "трек", "трека", "треков", "song", "songs")
    }
}
