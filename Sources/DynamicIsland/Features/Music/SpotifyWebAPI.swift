import Foundation

enum SpotifyAPIError: LocalizedError {
    case notSignedIn
    case invalidResponse
    case http(Int, String?)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return L("Spotify не подключён", "Spotify isn’t connected")
        case .invalidResponse:
            return L("Некорректный ответ Spotify", "Invalid response from Spotify")
        case .http(429, _):
            return L("Слишком много запросов к Spotify, попробуй позже", "Too many requests to Spotify. Try again later")
        case .http(403, let message):
            return L("Spotify отклонил запрос (403)\(message.map { ": \($0)" } ?? "")", "Spotify rejected the request (403)\(message.map { ": \($0)" } ?? "")")
        case .http(let status, let message):
            return L("Ошибка Spotify \(status)\(message.map { ": \($0)" } ?? "")", "Spotify error \(status)\(message.map { ": \($0)" } ?? "")")
        }
    }
}

/// Just the Web API endpoints the music tab needs: the queue, likes, playlists and search.
@MainActor
struct SpotifyWebAPI {
    let auth: SpotifyAuth

    private static let base = URL(string: "https://api.spotify.com/v1/")!
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func queue() async throws -> QueueResponse {
        guard let queue: QueueResponse = try await get(Self.base.appending(path: "me/player/queue")) else {
            // 204: nothing is playing on any device.
            return QueueResponse(currentlyPlaying: nil, queue: [])
        }
        return queue
    }

    /// "off", "context" or "track"; nil when nothing is playing.
    func repeatState() async throws -> String? {
        let state: PlaybackState? = try await get(Self.base.appending(path: "me/player"))
        return state?.repeatState
    }

    /// What's playing from: a playlist's, album's or artist's URI; nil for none.
    func playbackContext() async throws -> String? {
        let state: PlaybackState? = try await get(Self.base.appending(path: "me/player"))
        return state?.context?.uri
    }

    /// The user's own and followed playlists, in Spotify's order (up to `limit`).
    func playlists(limit: Int = 300) async throws -> [APIPlaylist] {
        var result: [APIPlaylist] = []
        var next: URL? = Self.url("me/playlists", query: ["limit": "50"])
        while let url = next, result.count < limit {
            guard let page: Page<Lossy<APIPlaylist>> = try await get(url) else { break }
            result += page.items.compactMap(\.value)
            next = page.next.flatMap(URL.init(string:))
        }
        return result
    }

    func currentUser() async throws -> APIUser? {
        try await get(Self.base.appending(path: "me"))
    }

    /// A page of a playlist's tracks; `next` continues it. Spotify only lists playlists the user
    /// has in their library (own or followed); others give 403.
    func playlistTracks(id: String) async throws -> (tracks: [APITrack], next: URL?) {
        try await trackPage(Self.url("playlists/\(id)/items", query: ["limit": "100"]))
    }

    /// A page of "Liked Songs", newest first.
    func likedTracks() async throws -> (tracks: [APITrack], next: URL?) {
        try await trackPage(Self.url("me/tracks", query: ["limit": "50"]))
    }

    /// The next page of either of the above.
    func trackPage(_ url: URL) async throws -> (tracks: [APITrack], next: URL?) {
        guard let page: Page<Lossy<PlaylistEntry>> = try await get(url) else { return ([], nil) }
        return (page.items.compactMap { $0.value?.track }, page.next.flatMap(URL.init(string:)))
    }

    /// How many songs are in "Liked Songs".
    func likedSongsCount() async throws -> Int? {
        let page: Page<Lossy<APITrack>>? = try await get(Self.url("me/tracks", query: ["limit": "1"]))
        return page?.total
    }

    func search(_ query: String, limit: Int = 10) async throws -> SearchResponse {
        let url = Self.url("search", query: ["q": query, "type": "track,artist,album,playlist", "limit": "\(limit)"])
        return try await get(url) ?? SearchResponse()
    }

    /// Needs Premium, like every playback command of the Web API.
    func addToQueue(_ uri: String) async throws {
        try await send("POST", Self.url("me/player/queue", query: ["uri": uri]))
    }

    func setRepeat(_ state: String) async throws {
        try await send("PUT", Self.url("me/player/repeat", query: ["state": state]))
    }

    /// Whether a track or episode (by Spotify URI) is in the user's library.
    func isSaved(_ uri: String) async throws -> Bool {
        let flags: [Bool]? = try await get(Self.url("me/library/contains", query: ["uris": uri]))
        return flags?.first ?? false
    }

    /// Adds a track or episode (by Spotify URI) to the user's library, or removes it.
    func setSaved(_ saved: Bool, uri: String) async throws {
        try await send(saved ? "PUT" : "DELETE", Self.url("me/library", query: ["uris": uri]))
    }

    private static func url(_ path: String, query: [String: String]) -> URL {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func send(_ method: String, _ url: URL, retryOnUnauthorized: Bool = true) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.invalidResponse }

        switch http.statusCode {
        case 200..<300:
            return
        case 401 where retryOnUnauthorized:
            auth.invalidateAccessToken()
            try await send(method, url, retryOnUnauthorized: false)
        default:
            let body = try? Self.decoder.decode(ErrorResponse.self, from: data)
            throw SpotifyAPIError.http(http.statusCode, body?.error.message)
        }
    }

    private func get<T: Decodable>(_ url: URL, retryOnUnauthorized: Bool = true) async throws -> T? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.invalidResponse }

        switch http.statusCode {
        case 204:
            return nil
        case 200..<300:
            return data.isEmpty ? nil : try Self.decoder.decode(T.self, from: data)
        case 401 where retryOnUnauthorized:
            auth.invalidateAccessToken()
            return try await get(url, retryOnUnauthorized: false)
        default:
            let body = try? Self.decoder.decode(ErrorResponse.self, from: data)
            throw SpotifyAPIError.http(http.statusCode, body?.error.message)
        }
    }
}

// MARK: - Models

struct APIImage: Decodable {
    let url: String
    let width: Int?
}

struct APIArtist: Decodable {
    let name: String
}

struct APIAlbum: Decodable {
    let uri: String?
    let name: String?
    let images: [APIImage]?
    let artists: [APIArtist]?
}

extension Array where Element == APIImage {
    /// Smallest image that is still sharp enough for a list row.
    func thumbnailURL() -> URL? {
        let sorted = sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        let image = sorted.first { ($0.width ?? 0) >= 64 } ?? sorted.last
        return image.flatMap { URL(string: $0.url) }
    }
}

struct APIFullArtist: Decodable {
    let uri: String
    let name: String
    let images: [APIImage]?
}

struct APIUser: Decodable {
    let id: String
    let displayName: String?
}

struct APIPlaylist: Decodable {
    struct Owner: Decodable {
        let id: String?
        let displayName: String?
    }
    struct Count: Decodable {
        let total: Int?
    }

    let id: String
    let uri: String
    let name: String
    let images: [APIImage]?
    let owner: Owner?
    /// The track count; newer API versions call it `items`.
    let tracks: Count?
    let items: Count?

    var trackCount: Int? { tracks?.total ?? items?.total }
}

/// An entry of a playlist (the track is under `item`) or of Liked Songs (under `track`).
struct PlaylistEntry: Decodable {
    let item: APITrack?
    let trackValue: APITrack?

    enum CodingKeys: String, CodingKey {
        case item
        case trackValue = "track"
    }

    var track: APITrack? { item ?? trackValue }
}

struct Page<Item: Decodable>: Decodable {
    let items: [Item]
    let next: String?
    let total: Int?
}

/// Search results by kind; each list skips entries it can't decode (Spotify returns nulls).
struct SearchResponse: Decodable {
    var tracks: [APITrack] = []
    var artists: [APIFullArtist] = []
    var albums: [APIAlbum] = []
    var playlists: [APIPlaylist] = []

    enum CodingKeys: String, CodingKey {
        case tracks, artists, albums, playlists
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func items<T: Decodable>(_ key: CodingKeys) -> [T] {
            let page = try? container.decodeIfPresent(Page<Lossy<T>>.self, forKey: key)
            return page?.items.compactMap(\.value) ?? []
        }
        tracks = items(.tracks)
        artists = items(.artists)
        albums = items(.albums)
        playlists = items(.playlists)
    }
}

struct APIShow: Decodable {
    let name: String
}

/// A track or a podcast episode.
struct APITrack: Decodable {
    let uri: String
    let name: String
    let durationMs: Int?
    let artists: [APIArtist]?
    let album: APIAlbum?
    let show: APIShow?
    let images: [APIImage]?

    var artistLine: String {
        if let artists, !artists.isEmpty { return artists.map(\.name).joined(separator: ", ") }
        return show?.name ?? ""
    }

    /// Smallest cover that is still sharp enough for a list row.
    func thumbnailURL() -> URL? {
        (album?.images ?? images ?? []).thumbnailURL()
    }
}

struct PlaybackState: Decodable {
    struct Context: Decodable {
        let uri: String?
    }
    let repeatState: String?
    let context: Context?
}

struct QueueResponse: Decodable {
    let currentlyPlaying: APITrack?
    let queue: [APITrack]

    enum CodingKeys: String, CodingKey {
        case currentlyPlaying, queue
    }

    init(currentlyPlaying: APITrack?, queue: [APITrack]) {
        self.currentlyPlaying = currentlyPlaying
        self.queue = queue
    }

    /// Skips entries it can't decode (local files, removed tracks, etc.).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentlyPlaying = try? container.decodeIfPresent(APITrack.self, forKey: .currentlyPlaying)
        queue = (try container.decodeIfPresent([Lossy<APITrack>].self, forKey: .queue) ?? []).compactMap(\.value)
    }
}

struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct ErrorResponse: Decodable {
    struct Body: Decodable {
        let message: String?
    }
    let error: Body
}
