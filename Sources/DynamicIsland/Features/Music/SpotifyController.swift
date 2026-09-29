import AppKit
import Combine
import SwiftUI

private let spotifyBundleID = "com.spotify.client"

struct SpotifyTrack: Equatable {
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

/// Talks to the Spotify desktop app via AppleScript and its distributed notifications.
/// The Web API is used only for what AppleScript can't do: repeating a single track.
@MainActor
final class SpotifyController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying = false
    @Published private(set) var track: SpotifyTrack?
    @Published private(set) var artwork: NSImage?
    /// Accent colors from the cover for the equalizer; nil for a colorless cover or no cover.
    @Published private(set) var artworkColors: [Color]?
    @Published private(set) var permissionDenied = false
    /// Spotify's own volume, 0...100.
    @Published private(set) var volume = 50
    @Published private(set) var isShuffling = false
    @Published private(set) var repeatMode: RepeatMode = .off
    /// Whether the current track is in the user's library; nil while unknown.
    @Published private(set) var isLiked: Bool?

    private let auth: SpotifyAuth
    private let api: SpotifyWebAPI
    /// After toggling shuffle/repeat, ignore readings for a moment: a refresh already in flight
    /// would briefly flip the button back.
    private var modesLockedUntil = Date.distantPast
    /// Same for the volume while it's being changed: Spotify reports the old value for a moment.
    private var volumeLockedUntil = Date.distantPast
    /// Sends the latest volume; changes made while it waits are folded into it.
    private var volumeTask: Task<Void, Never>?

    /// Last known position and when it was sampled; the UI interpolates between samples.
    @Published private var playhead = (position: 0.0, date: Date())

    private var pollTimer: Timer?
    private let scripts = AppleScriptRunner()
    private var isRefreshing = false
    /// A refresh was requested while one was in flight; run it once that one finishes.
    private var needsRefresh = false
    private var artworkTask: Task<Void, Never>?
    private var likeTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private static let stateScript = """
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

    init(auth: SpotifyAuth) {
        self.auth = auth
        self.api = SpotifyWebAPI(auth: auth)
        isRunning = Self.spotifyIsRunning

        let distributed = DistributedNotificationCenter.default()
        let playbackToken = distributed.addObserver(
            forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] note in
            let state = note.userInfo?["Player State"] as? String
            MainActor.assumeIsolated { self?.handlePlaybackChanged(state: state) }
        }
        observers.append((distributed, playbackToken))

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == spotifyBundleID else { return }
                let launched = name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated { self?.handleLifecycle(launched: launched) }
            }
            observers.append((workspace, token))
        }

        refresh()
    }

    deinit {
        for (center, token) in observers { center.removeObserver(token) }
    }

    private static var spotifyIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleID).isEmpty
    }

    // MARK: - Public API

    /// Current playback position in seconds, extrapolated to `date` while playing.
    func position(at date: Date) -> Double {
        guard let track else { return 0 }
        var value = playhead.position
        if isPlaying { value += date.timeIntervalSince(playhead.date) }
        return min(max(value, 0), track.duration)
    }

    /// Poll frequently while the player is visible so the position stays in sync.
    func setActive(_ active: Bool) {
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

    /// Repeating a single track needs the Web API with playback control.
    var canRepeatTrack: Bool {
        auth.isSignedIn && auth.canControlPlayback
    }

    /// The like button is shown: signed in to the Web API, and the track can be saved
    /// (local files and ads can't).
    var showsLike: Bool {
        guard auth.isSignedIn, let id = track?.id else { return false }
        return id.hasPrefix("spotify:track:") || id.hasPrefix("spotify:episode:")
    }

    /// False for a session authorized before likes were added: the button reconnects instead.
    var canLike: Bool { showsLike && auth.canUseLibrary }

    /// Signs in again to grant the library permissions (the browser opens for a moment).
    func reconnectForLikes() {
        auth.signOut()
        auth.signIn()
    }

    /// Adds the current track to the library ("Liked Songs"), or removes it.
    func toggleLike() {
        guard canLike, let uri = track?.id else { return }
        let liked = isLiked ?? false
        likeTask?.cancel()
        isLiked = !liked
        Task {
            do {
                try await api.setSaved(!liked, uri: uri)
            } catch {
                if track?.id == uri { isLiked = liked }
            }
        }
    }

    func toggleShuffle() {
        isShuffling.toggle()
        modesLockedUntil = Date().addingTimeInterval(1.5)
        command("set shuffling to \(isShuffling)", cache: false)
    }

    /// Off → playlist → track → off, like Spotify's button. Without the Web API: off ↔ playlist.
    func cycleRepeatMode() {
        let next: RepeatMode
        switch repeatMode {
        case .off: next = .context
        case .context: next = canRepeatTrack ? .track : .off
        case .track: next = .off
        }
        repeatMode = next
        modesLockedUntil = Date().addingTimeInterval(1.5)

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

    /// Plays a playlist, album, artist or track by its Spotify URI; a track `context` makes
    /// playback go on through that playlist or album. AppleScript does this without Premium.
    /// Starts Spotify first if it isn't running.
    func play(_ uri: String, context: String? = nil) {
        guard Self.isSafeURI(uri), context.map(Self.isSafeURI) ?? true else { return }
        let script = context.map { "play track \"\(uri)\" in context \"\($0)\"" } ?? "play track \"\(uri)\""
        keepInBackground()
        guard Self.spotifyIsRunning else {
            openSpotify(inBackground: true)
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

    /// Updates right away; Spotify gets the value at most every 80 ms, so a scroll gesture's
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

    func openSpotify(inBackground: Bool = false) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: spotifyBundleID) else { return }
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
        let previous = NSWorkspace.shared.frontmostApplication
        guard previous?.bundleIdentifier != spotifyBundleID else { return }
        let wasHidden = NSRunningApplication.runningApplications(withBundleIdentifier: spotifyBundleID).first?.isHidden ?? true
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == spotifyBundleID else { return }
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
        isRunning = Self.spotifyIsRunning
        // Never script Spotify when it's not running: `tell application` would launch it.
        guard isRunning else { clearState(); return }
        guard !isRefreshing else {
            needsRefresh = true
            return
        }

        isRefreshing = true
        Task {
            let output = handle(await scripts.run(Self.stateScript, cache: true, targetBundleID: spotifyBundleID))
            isRefreshing = false
            if let output { apply(output) }
            if needsRefresh {
                needsRefresh = false
                refresh()
            }
        }
    }

    // MARK: - Private

    /// AppleScript can't tell "repeat playlist" from "repeat track"; the Web API can.
    private func syncRepeatMode() {
        guard canRepeatTrack else { return }
        Task {
            guard let state = try? await api.repeatState(), Date() > modesLockedUntil else { return }
            let mode = RepeatMode(apiValue: state)
            if mode != repeatMode { repeatMode = mode }
        }
    }

    private func loadLiked() {
        likeTask?.cancel()
        guard canLike, let uri = track?.id else { return }
        likeTask = Task {
            guard let saved = try? await api.isSaved(uri), !Task.isCancelled, track?.id == uri else { return }
            isLiked = saved
        }
    }

    private func handlePlaybackChanged(state: String?) {
        if state == "Stopped" {
            // Also sent while Spotify quits; don't script it here or we might relaunch it.
            isPlaying = false
            return
        }
        refresh()
    }

    private func handleLifecycle(launched: Bool) {
        isRunning = launched
        if launched {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else {
            clearState()
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
        guard Self.spotifyIsRunning else { return }
        let source = "tell application id \"\(spotifyBundleID)\"\n\(command)\nend tell"
        Task {
            handle(await scripts.run(source, cache: cache, targetBundleID: spotifyBundleID))
            try? await Task.sleep(for: .milliseconds(300))
            refresh()
        }
    }

    private func apply(_ output: String) {
        // state, volume, shuffling, repeating, then the track fields if there is a current track.
        let lines = output.components(separatedBy: "\n")
        isPlaying = lines.first == "playing"
        if lines.count > 1, Date() > volumeLockedUntil, let newVolume = Self.parseNumber(lines[1]).map({ Int($0.rounded()) }), newVolume != volume {
            volume = newVolume
        }
        if lines.count > 3, Date() > modesLockedUntil {
            let shuffling = lines[2] == "true"
            if shuffling != isShuffling { isShuffling = shuffling }
            // AppleScript only knows on/off; "on" can be either mode, so keep "track" if we set it.
            let repeating = lines[3] == "true"
            let mode: RepeatMode = !repeating ? .off : repeatMode == .off ? .context : repeatMode
            if mode != repeatMode { repeatMode = mode }
        }

        guard lines.count >= 11 else {
            clearState()
            return
        }

        let newTrack = SpotifyTrack(
            id: lines[4],
            title: lines[5],
            artist: lines[6],
            album: lines[7],
            artworkURL: URL(string: lines[8]),
            duration: (Self.parseNumber(lines[9]) ?? 0) / 1000
        )
        if newTrack != track {
            if newTrack.artworkURL != track?.artworkURL { loadArtwork(newTrack.artworkURL) }
            let isNewTrack = newTrack.id != track?.id
            track = newTrack
            if isNewTrack {
                isLiked = nil
                loadLiked()
            }
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
            let image = NSImage(data: data)
            self?.artwork = image
            self?.artworkColors = image.flatMap(ArtworkPalette.colors(from:))
        }
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
