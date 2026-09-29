import AppKit
import CryptoKit
import Foundation

/// OAuth (Authorization Code + PKCE) for the Spotify Web API with a loopback redirect.
@MainActor
final class SpotifyAuth: ObservableObject {
    static let redirectPort: UInt16 = 43821
    static let redirectURI = "http://127.0.0.1:\(redirectPort)/callback"
    /// Needed for "repeat one track": AppleScript only toggles repeat on/off (the whole playlist).
    static let playbackControlScope = "user-modify-playback-state"
    /// Needed for the like button: checking and changing what's in the user's library.
    static let libraryScopes = ["user-library-read", "user-library-modify"]
    /// Needed for the playlists pane: the user's own and followed playlists, private ones too.
    static let playlistScopes = ["playlist-read-private", "playlist-read-collaborative"]
    private static let scopes = ["user-read-playback-state", "user-read-currently-playing", playbackControlScope] + libraryScopes + playlistScopes
    private static let clientIDKey = "spotifyClientID"

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDKey) }
    }
    @Published private(set) var isSignedIn: Bool
    /// False for sessions authorized before playback control was added: those need to reconnect.
    @Published private(set) var canControlPlayback: Bool
    /// False for sessions authorized before likes were added.
    @Published private(set) var canUseLibrary: Bool
    /// False for sessions authorized before playlists were added.
    @Published private(set) var canReadPlaylists: Bool
    @Published private(set) var isSigningIn = false
    @Published private(set) var lastError: String?

    private var token: StoredToken? {
        didSet {
            TokenStore.save(token)
            isSignedIn = token != nil
            canControlPlayback = Self.grants(token, Self.playbackControlScope)
            canUseLibrary = Self.libraryScopes.allSatisfy { Self.grants(token, $0) }
            canReadPlaylists = Self.playlistScopes.allSatisfy { Self.grants(token, $0) }
        }
    }
    private var callbackServer: LoopbackServer?
    private var refreshTask: Task<String, Error>?

    init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        let stored = TokenStore.load()
        token = stored
        isSignedIn = stored != nil
        canControlPlayback = Self.grants(stored, Self.playbackControlScope)
        canUseLibrary = Self.libraryScopes.allSatisfy { Self.grants(stored, $0) }
        canReadPlaylists = Self.playlistScopes.allSatisfy { Self.grants(stored, $0) }
    }

    private static func grants(_ token: StoredToken?, _ scope: String) -> Bool {
        token?.scope?.split(separator: " ").contains(Substring(scope)) ?? false
    }

    var hasClientID: Bool { !trimmedClientID.isEmpty }

    /// Signed in, but before some permission was added: reconnecting grants it.
    var needsReconnect: Bool { isSignedIn && !(canControlPlayback && canUseLibrary && canReadPlaylists) }

    private var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sign in / out

    func signIn() {
        let clientID = trimmedClientID
        guard !clientID.isEmpty else {
            lastError = L("Укажи Client ID", "Enter a Client ID")
            return
        }

        let verifier = Self.randomString(length: 64)
        let state = Self.randomString(length: 16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]

        callbackServer?.stop()
        let server = LoopbackServer(port: Self.redirectPort) { [weak self] params in
            self?.handleCallback(params, expectedState: state, verifier: verifier, clientID: clientID)
        }
        do {
            try server.start()
        } catch {
            lastError = L("Не удалось открыть порт \(Self.redirectPort): \(error.localizedDescription)", "Couldn’t open port \(Self.redirectPort): \(error.localizedDescription)")
            return
        }
        callbackServer = server
        isSigningIn = true
        lastError = nil
        NSWorkspace.shared.open(components.url!)
    }

    func signOut() {
        callbackServer?.stop()
        callbackServer = nil
        isSigningIn = false
        token = nil
    }

    private func handleCallback(_ params: [String: String], expectedState: String, verifier: String, clientID: String) {
        callbackServer?.stop()
        callbackServer = nil

        guard params["state"] == expectedState, let code = params["code"] else {
            isSigningIn = false
            lastError = params["error"].map { "Spotify: \($0)" } ?? L("Авторизация отменена", "Sign-in canceled")
            return
        }

        Task {
            do {
                token = try await requestToken([
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": Self.redirectURI,
                    "client_id": clientID,
                    "code_verifier": verifier,
                ], previousRefreshToken: nil)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
            isSigningIn = false
        }
    }

    // MARK: - Tokens

    func accessToken() async throws -> String {
        guard let token else { throw SpotifyAPIError.notSignedIn }
        if token.expiresAt > Date().addingTimeInterval(60) {
            return token.accessToken
        }
        return try await refreshAccessToken()
    }

    /// Forces a refresh on the next request, e.g. after a 401.
    func invalidateAccessToken() {
        token?.expiresAt = .distantPast
    }

    private func refreshAccessToken() async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }
        guard let refreshToken = token?.refreshToken else { throw SpotifyAPIError.notSignedIn }

        let task = Task { () throws -> String in
            defer { refreshTask = nil }
            do {
                let newToken = try await requestToken([
                    "grant_type": "refresh_token",
                    "refresh_token": refreshToken,
                    "client_id": trimmedClientID,
                ], previousRefreshToken: refreshToken)
                token = newToken
                return newToken.accessToken
            } catch SpotifyAPIError.http(let status, let message) where status == 400 || status == 401 {
                // Refresh token revoked or expired: the user has to sign in again.
                token = nil
                throw SpotifyAPIError.http(status, message)
            }
        }
        refreshTask = task
        return try await task.value
    }

    private func requestToken(_ form: [String: String], previousRefreshToken: String?) async throws -> StoredToken {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(TokenErrorResponse.self, from: data)
            throw SpotifyAPIError.http(http.statusCode, body?.errorDescription ?? body?.error)
        }

        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refreshToken = decoded.refresh_token ?? previousRefreshToken else {
            throw SpotifyAPIError.invalidResponse
        }
        return StoredToken(
            accessToken: decoded.access_token,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)),
            // A refresh may omit the scope; the granted scopes don't change then.
            scope: decoded.scope ?? token?.scope
        )
    }

    // MARK: - Helpers

    private static func randomString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
    let scope: String?
}

private struct TokenErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

struct StoredToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// Space-separated scopes the user granted. Missing in tokens saved by older versions.
    var scope: String?
}

/// Persists the token in Application Support, readable only by the current user.
/// (Not the Keychain: the app is ad-hoc signed, so every rebuild would trigger a Keychain prompt.)
enum TokenStore {
    private static var fileURL: URL {
        AppSettings.dataDirectory.appending(path: "spotify-token.json")
    }

    static func load() -> StoredToken? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(StoredToken.self, from: data)
    }

    static func save(_ token: StoredToken?) {
        let fileManager = FileManager.default
        guard let token, let data = try? JSONEncoder().encode(token) else {
            try? fileManager.removeItem(at: fileURL)
            return
        }
        try? fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: fileURL)
        fileManager.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
