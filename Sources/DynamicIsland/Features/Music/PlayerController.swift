import AppKit
import Combine
import SwiftUI

/// A music app the notch can control through its AppleScript dictionary and the distributed
/// notifications it posts. No private frameworks: macOS has no public "now playing" API for
/// other apps, so browsers and apps without a dictionary aren't covered.
enum MusicApp: String, CaseIterable, Identifiable {
    case spotify
    case appleMusic

    var id: String { rawValue }

    var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .appleMusic: "com.apple.Music"
        }
    }

    var name: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        }
    }

    /// Posted by the app whenever playback or the track changes.
    var playbackNotification: Notification.Name {
        switch self {
        case .spotify: .init("com.spotify.client.PlaybackStateChanged")
        case .appleMusic: .init("com.apple.Music.playerInfo")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Player state, volume, shuffle and repeat, then the track's fields if there is a current
    /// track: id, title, artist, album, then the artwork URL (Spotify) or whether it's a
    /// favorite (Apple Music), the duration and the position.
    fileprivate var stateScript: String {
        switch self {
        case .spotify:
            """
            tell application id "com.spotify.client"
                set out to (player state as string) & linefeed & (sound volume as string) ¬
                    & linefeed & (shuffling as string) & linefeed & (repeating as string)
                try
                    set t to current track
                    set out to out & linefeed & (id of t) & linefeed & (name of t) & linefeed & (artist of t) ¬
                        & linefeed & (album of t) & linefeed & (artwork url of t) ¬
                        & linefeed & ((duration of t) as string) & linefeed & ((player position) as string)
                end try
                return out
            end tell
            """
        case .appleMusic:
            """
            tell application id "com.apple.Music"
                set out to (player state as string) & linefeed & (sound volume as string) ¬
                    & linefeed & (shuffle enabled as string) & linefeed & (song repeat as string)
                try
                    set t to current track
                    set fav to ""
                    try
                        set fav to (favorited of t) as string
                    end try
                    set out to out & linefeed & (persistent ID of t) & linefeed & (name of t) & linefeed & (artist of t) ¬
                        & linefeed & (album of t) & linefeed & fav ¬
                        & linefeed & ((duration of t) as string) & linefeed & ((player position) as string)
                end try
                return out
            end tell
            """
        }
    }
}

struct Track: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    /// Seconds.
    let duration: Double
}

enum RepeatMode {
    case off
    /// The whole playlist/album.
    case context
    /// The current track.
    case track

    init(apiValue: String) {
        switch apiValue {
        case "context": self = .context
        case "track": self = .track
        default: self = .off
        }
    }

    var apiValue: String {
        switch self {
        case .off: "off"
        case .context: "context"
        case .track: "track"
        }
    }
}

/// Controls Spotify or Apple Music via AppleScript and follows them through their distributed
/// notifications. With Spotify, the Web API adds what AppleScript can't do: likes and repeating
/// a single track. Apple Music's own dictionary covers both.
@MainActor
final class PlayerController: ObservableObject {
    /// The app being shown and controlled.
    @Published private(set) var app: MusicApp
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying = false
    @Published private(set) var track: Track?
    @Published private(set) var artwork: NSImage?
    /// Accent colors from the cover for the equalizer; nil for a colorless cover or no cover.
    @Published private(set) var artworkColors: [Color]?
    @Published private(set) var permissionDenied = false
    /// The app's own volume, 0...100.
    @Published private(set) var volume = 50
    @Published private(set) var isShuffling = false
    @Published private(set) var repeatMode: RepeatMode = .off
    /// Whether the current track is liked (Spotify) or a favorite (Apple Music); nil while unknown.
    @Published private(set) var isLiked: Bool?

    private let auth: SpotifyAuth
    private let api: SpotifyWebAPI
    /// After toggling shuffle/repeat/like, ignore readings for a moment: a refresh already in
    /// flight would briefly flip the button back.
    private var modesLockedUntil = Date.distantPast
    /// Same for the volume while it's being changed: the app reports the old value for a moment.
    private var volumeLockedUntil = Date.distantPast
    /// Sends the latest volume; changes made while it waits are folded into it.
    private var volumeTask: Task<Void, Never>?

    /// Last known position and when it was sampled; the UI interpolates between samples.
    @Published private var playhead = (position: 0.0, date: Date())

    private var pollTimer: Timer?
    private var isActive = false
    private let scripts = AppleScriptRunner()
    private var isRefreshing = false
    /// A refresh was requested while one was in flight; run it once that one finishes.
    private var needsRefresh = false
    private var artworkTask: Task<Void, Never>?
    private var likeTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private static let lastAppKey = "lastMusicApp"

    init(auth: SpotifyAuth) {
        self.auth = auth
        self.api = SpotifyWebAPI(auth: auth)
        app = Self.initialApp()
        isRunning = app.isRunning

        let distributed = DistributedNotificationCenter.default()
        for musicApp in MusicApp.allCases {
            let token = distributed.addObserver(forName: musicApp.playbackNotification, object: nil, queue: .main) { [weak self] note in
                let state = note.userInfo?["Player State"] as? String
                MainActor.assumeIsolated { self?.handlePlaybackChanged(in: musicApp, state: state) }
            }
            observers.append((distributed, token))
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                guard let musicApp = MusicApp.allCases.first(where: { $0.bundleID == bundleID }) else { return }
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated { self?.handleLifecycle(of: musicApp, launched: launched) }
            }
            observers.append((workspace, token))
        }

        refresh()
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    /// The one used last if it's running, or whichever is.
    private static func initialApp() -> MusicApp {
        let last = UserDefaults.standard.string(forKey: lastAppKey).flatMap(MusicApp.init(rawValue:))
        if let last, last.isRunning { return last }
        if let running = MusicApp.allCases.first(where: \.isRunning) { return running }
        return last ?? (MusicApp.spotify.isInstalled ? .spotify : .appleMusic)
    }

    // MARK: - Public API

    /// Spotify with the Web API connected: the queue, playlists and search are there too.
    var hasLibrary: Bool {
        app == .spotify && auth.isSignedIn
    }

    /// Current playback position in seconds, extrapolated to `date` while playing.
    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        var value = playhead.position
        if isPlaying { value += date.timeIntervalSince(playhead.date) }
        return min(max(value, 0), track.duration)
    }

    /// Poll frequently while the player is visible so the position stays in sync.
    func setActive(_ active: Bool) {
        isActive = active
        pollTimer?.invalidate()
        pollTimer = nil
        guard active else { return }
        refresh()
        syncRepeatMode()
        if isLiked == nil { loadLiked() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Repeating a single track: Apple Music can by itself; Spotify needs the Web API.
    var canRepeatTrack: Bool {
        app == .appleMusic || (auth.isSignedIn && auth.canControlPlayback)
    }

    /// The like button is shown: for Apple Music any track; for Spotify when signed in to the
    /// Web API and the track can be saved (local files and ads can't).
    var showsLike: Bool {
        guard let id = track?.id else { return false }
        switch app {
        case .appleMusic: return true
        case .spotify: return auth.isSignedIn && (id.hasPrefix("spotify:track:") || id.hasPrefix("spotify:episode:"))
        }
    }

    /// False for a Spotify session authorized before likes were added: the button reconnects instead.
    var canLike: Bool { showsLike && (app == .appleMusic || auth.canUseLibrary) }

    /// Signs in again to grant the library permissions (the browser opens for a moment).
    func reconnectForLikes() {
        auth.signOut()
        auth.signIn()
    }

    /// Adds the current track to Spotify's "Liked Songs" or Apple Music's favorites, or removes it.
    func toggleLike() {
        guard canLike, let id = track?.id else { return }
        let liked = isLiked ?? false
        likeTask?.cancel()
        isLiked = !liked
        switch app {
        case .appleMusic:
            modesLockedUntil = Date().addingTimeInterval(1.5)
            command("set favorited of current track to \(!liked)", cache: false)
        case .spotify:
            Task {
                do {
                    try await api.setSaved(!liked, uri: id)
                } catch {
                    if track?.id == id { isLiked = liked }
                }
            }
        }
    }

    func toggleShuffle() {
        isShuffling.toggle()
        modesLockedUntil = Date().addingTimeInterval(1.5)
        switch app {
        case .spotify: command("set shuffling to \(isShuffling)", cache: false)
        case .appleMusic: command("set shuffle enabled to \(isShuffling)", cache: false)
        }
    }

    /// Off → playlist → track → off, like the apps' own buttons. Spotify without the Web API:
    /// off ↔ playlist.
    func cycleRepeatMode() {
        let next: RepeatMode
        switch repeatMode {
        case .off: next = .context
        case .context: next = canRepeatTrack ? .track : .off
        case .track: next = .off
        }
        repeatMode = next
        modesLockedUntil = Date().addingTimeInterval(1.5)

        if app == .appleMusic {
            let value = switch next {
            case .off: "off"
            case .context: "all"
            case .track: "one"
            }
            command("set song repeat to \(value)", cache: false)
            return
        }
        guard canRepeatTrack else {
            command("set repeating to \(next != .off)", cache: false)
            return
        }
        Task {
            do {
                try await api.setRepeat(next.apiValue)
            } catch {
                // No Premium or no active device: AppleScript can still do on/off.
                if next == .track { repeatMode = .context }
                command("set repeating to \(next != .off)", cache: false)
            }
        }
    }

    func playPause() {
        let now = Date()
        playhead = (position(at: now), now)
        isPlaying.toggle()
        command("playpause")
    }

    /// Plays a Spotify playlist, album, artist or track by its URI; a track `context` makes
    /// playback go on through that playlist or album. AppleScript does this without Premium.
    /// Starts Spotify first if it isn't running, and follows it from then on.
    func play(_ uri: String, context: String? = nil) {
        guard Self.isSafeURI(uri), context.map(Self.isSafeURI) ?? true else { return }
        if app != .spotify { switchTo(.spotify) }
        let script = context.map { "play track \"\(uri)\" in context \"\($0)\"" } ?? "play track \"\(uri)\""
        keepInBackground()
        guard MusicApp.spotify.isRunning else {
            openApp(inBackground: true)
            // The app needs a moment before it takes scripts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                MainActor.assumeIsolated { self?.command(script, cache: false) }
            }
            return
        }
        command(script, cache: false)
    }

    /// Only "spotify:…" URIs made of safe characters go into AppleScript source.
    private static func isSafeURI(_ uri: String) -> Bool {
        uri.hasPrefix("spotify:") && uri.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ":._-".contains($0)) }
    }

    func nextTrack() { command("next track") }

    func previousTrack() { command("previous track") }

    /// Jumps forward through the queue, like clicking a queued track in Spotify.
    func skip(times: Int) {
        guard times > 0 else { return }
        command(times == 1 ? "next track" : "repeat \(times) times\nnext track\nend repeat", cache: false)
    }

    func seek(to seconds: Double) {
        playhead = (seconds, Date())
        // Double's description is locale-independent, which AppleScript source requires.
        command("set player position to \(seconds)", cache: false)
    }

    /// Updates right away; the app gets the value at most every 80 ms, so a scroll gesture's
    /// many small steps don't queue up a script each.
    func setVolume(_ value: Int) {
        volume = min(max(value, 0), 100)
        volumeLockedUntil = Date().addingTimeInterval(1.5)
        guard volumeTask == nil else { return }
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            volumeTask = nil
            command("set sound volume to \(volume)", cache: false)
        }
    }

    func openApp(inBackground: Bool = false) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        if inBackground {
            configuration.activates = false
            configuration.hides = true
        }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Spotify may come to the front when told to play something. Picking music in the notch
    /// shouldn't pull you out of what you're doing: for a few seconds, if Spotify activates,
    /// the app you were in gets the focus back (and Spotify hides again if it was hidden).
    private func keepInBackground() {
        let bundleID = MusicApp.spotify.bundleID
        let previous = NSWorkspace.shared.frontmostApplication
        guard previous?.bundleIdentifier != bundleID else { return }
        let wasHidden = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.isHidden ?? true
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == bundleID else { return }
            if wasHidden { app?.hide() }
            previous?.activate()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { center.removeObserver(token) }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        isRunning = app.isRunning
        // Never script an app that's not running: `tell application` would launch it.
        guard isRunning else { clearState(); return }
        guard !isRefreshing else {
            needsRefresh = true
            return
        }

        isRefreshing = true
        let app = app
        Task {
            let output = handle(await scripts.run(app.stateScript, cache: true, targetBundleID: app.bundleID))
            isRefreshing = false
            // The app may have been switched while the script ran.
            if let output, app == self.app { apply(output) }
            if needsRefresh {
                needsRefresh = false
                refresh()
            }
        }
    }

    // MARK: - Private

    private func switchTo(_ newApp: MusicApp) {
        guard newApp != app else { return }
        clearState()
        repeatMode = .off
        permissionDenied = false
        app = newApp
        UserDefaults.standard.set(newApp.rawValue, forKey: Self.lastAppKey)
        refresh()
        if isActive { syncRepeatMode() }
    }

    /// AppleScript can't tell Spotify's "repeat playlist" from "repeat track"; the Web API can.
    private func syncRepeatMode() {
        guard app == .spotify, canRepeatTrack else { return }
        Task {
            guard let state = try? await api.repeatState(), Date() > modesLockedUntil, app == .spotify else { return }
            let mode = RepeatMode(apiValue: state)
            if mode != repeatMode { repeatMode = mode }
        }
    }

    /// Spotify's likes come from the Web API; Apple Music reports favorites with the state.
    private func loadLiked() {
        likeTask?.cancel()
        guard app == .spotify, canLike, let uri = track?.id else { return }
        likeTask = Task {
            guard let saved = try? await api.isSaved(uri), !Task.isCancelled, track?.id == uri else { return }
            isLiked = saved
        }
    }

    private func handlePlaybackChanged(in source: MusicApp, state: String?) {
        guard source == app else {
            // Follow whichever app starts playing.
            if state == "Playing" { switchTo(source) }
            return
        }
        if state == "Stopped" {
            // Also sent while the app quits; don't script it here or we might relaunch it.
            isPlaying = false
            return
        }
        refresh()
    }

    private func handleLifecycle(of musicApp: MusicApp, launched: Bool) {
        if musicApp != app {
            // The app we follow isn't running and another one starts: follow that one.
            if launched, !app.isRunning { switchTo(musicApp) }
            return
        }
        isRunning = launched
        if launched {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else {
            clearState()
            // The other one may still be playing.
            if let other = MusicApp.allCases.first(where: { $0 != musicApp && $0.isRunning }) {
                switchTo(other)
            }
        }
    }

    private func clearState() {
        isPlaying = false
        if track != nil { track = nil }
        if artwork != nil { artwork = nil }
        if artworkColors != nil { artworkColors = nil }
        artworkTask?.cancel()
        likeTask?.cancel()
        if isLiked != nil { isLiked = nil }
    }

    private func command(_ command: String, cache: Bool = true) {
        let app = app
        guard app.isRunning else { return }
        let source = "tell application id \"\(app.bundleID)\"\n\(command)\nend tell"
        Task {
            handle(await scripts.run(source, cache: cache, targetBundleID: app.bundleID))
            try? await Task.sleep(for: .milliseconds(300))
            refresh()
        }
    }

    private func apply(_ output: String) {
        // See `MusicApp.stateScript` for the lines.
        let lines = output.components(separatedBy: "\n")
        isPlaying = lines.first == "playing"
        if lines.count > 1, Date() > volumeLockedUntil, let newVolume = Self.parseNumber(lines[1]).map({ Int($0.rounded()) }), newVolume != volume {
            volume = newVolume
        }
        if lines.count > 3, Date() > modesLockedUntil {
            let shuffling = lines[2] == "true"
            if shuffling != isShuffling { isShuffling = shuffling }
            let mode: RepeatMode = switch app {
            case .appleMusic:
                lines[3] == "one" ? .track : lines[3] == "all" ? .context : .off
            case .spotify:
                // AppleScript only knows on/off; "on" can be either mode, so keep "track" if we set it.
                lines[3] != "true" ? .off : repeatMode == .off ? .context : repeatMode
            }
            if mode != repeatMode { repeatMode = mode }
        }

        guard lines.count >= 11 else {
            clearState()
            return
        }

        let duration = Self.parseNumber(lines[9]) ?? 0
        let newTrack = Track(
            id: lines[4],
            title: lines[5],
            artist: lines[6],
            album: lines[7],
            artworkURL: app == .spotify ? URL(string: lines[8]) : nil,
            // Spotify counts in milliseconds, Apple Music in seconds.
            duration: app == .spotify ? duration / 1000 : duration
        )
        if newTrack != track {
            let isNewTrack = newTrack.id != track?.id
            switch app {
            case .spotify:
                if newTrack.artworkURL != track?.artworkURL { loadArtwork(newTrack.artworkURL) }
            case .appleMusic:
                // Tracks of one album share the cover.
                if newTrack.album != track?.album || newTrack.artist != track?.artist || artwork == nil { loadMusicArtwork() }
            }
            track = newTrack
            if isNewTrack {
                isLiked = nil
                loadLiked()
            }
        }
        if app == .appleMusic, Date() > modesLockedUntil {
            let favorite: Bool? = lines[8] == "true" ? true : lines[8] == "false" ? false : nil
            if favorite != isLiked { isLiked = favorite }
        }
        playhead = (Self.parseNumber(lines[10]) ?? 0, Date())
    }

    /// AppleScript formats reals using the system locale, e.g. "12,5" with a Russian locale.
    private static func parseNumber(_ string: String) -> Double? {
        Double(string.replacingOccurrences(of: ",", with: "."))
    }

    private func loadArtwork(_ url: URL?) {
        artworkTask?.cancel()
        artwork = nil
        guard let url else {
            artworkColors = nil
            return
        }
        // The previous colors stay until the new cover arrives, so the equalizer doesn't flash green.
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), !Task.isCancelled else { return }
            self?.setArtwork(NSImage(data: data))
        }
    }

    /// Apple Music hands over the cover itself, as image data.
    private func loadMusicArtwork() {
        artworkTask?.cancel()
        artwork = nil
        let bundleID = MusicApp.appleMusic.bundleID
        let source = "tell application id \"\(bundleID)\" to get raw data of artwork 1 of current track"
        artworkTask = Task { [weak self, scripts] in
            let data = await scripts.runForData(source, targetBundleID: bundleID)
            guard !Task.isCancelled, let self, app == .appleMusic else { return }
            if let data {
                setArtwork(NSImage(data: data))
            } else {
                // Some tracks (radio, some streams) have no cover.
                artworkColors = nil
            }
        }
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        artworkColors = image.flatMap(ArtworkPalette.colors(from:))
    }

    /// Updates the permission state and returns the script's output, if any.
    @discardableResult
    private func handle(_ outcome: AppleScriptRunner.Outcome) -> String? {
        switch outcome {
        case .success(let output):
            if permissionDenied { permissionDenied = false }
            return output
        case .notPermitted:
            permissionDenied = true
            return nil
        case .failed:
            return nil
        }
    }
}
