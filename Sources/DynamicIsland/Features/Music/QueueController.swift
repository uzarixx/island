import Combine
import Foundation

struct QueueTrack: Identifiable, Equatable {
    /// Includes the position: the same track can be queued more than once.
    let id: String
    let uri: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let duration: Double
    /// How many times to skip forward to reach this track (0 = playing now).
    let skips: Int
}

/// Spotify's queue as the app shows it: what's playing now and what's next.
/// Needs the Web API: Spotify's AppleScript doesn't expose the queue.
@MainActor
final class QueueController: ObservableObject {
    enum State: Equatable {
        case needsSetup, signedOut, loading, loaded, failed(String)
    }

    @Published private(set) var state: State = .signedOut
    @Published private(set) var upcoming: [QueueTrack] = []

    let auth: SpotifyAuth
    private let player: PlayerController
    private let api: SpotifyWebAPI
    private var isActive = false
    private var loadTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    static let currentID = "current"

    init(auth: SpotifyAuth, player: PlayerController) {
        self.auth = auth
        self.player = player
        self.api = SpotifyWebAPI(auth: auth)
        // Earlier versions kept a playback history here.
        UserDefaults.standard.removeObject(forKey: "playbackHistory")

        player.$track
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] trackID in self?.trackChanged(to: trackID) }
            .store(in: &cancellables)

        auth.$isSignedIn
            .removeDuplicates()
            .sink { [weak self] signedIn in
                guard let self else { return }
                if !signedIn { upcoming = [] }
                // Published values change in willSet; read the new one on the next runloop turn.
                DispatchQueue.main.async { self.reload() }
            }
            .store(in: &cancellables)
    }

    /// The current track (from AppleScript, so it's always up to date), then the queue.
    var items: [QueueTrack] {
        guard let current = player.track else { return upcoming }
        let now = QueueTrack(
            id: Self.currentID,
            uri: current.id,
            title: current.title,
            artist: current.artist,
            artworkURL: current.artworkURL,
            duration: current.duration,
            skips: 0
        )
        return [now] + upcoming
    }

    /// Fetch the queue only while it's on screen.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active { reload() }
    }

    func reload(delay: Duration = .zero) {
        guard auth.hasClientID else { state = .needsSetup; return }
        guard auth.isSignedIn else { state = .signedOut; return }
        guard isActive else { return }

        loadTask?.cancel()
        loadTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    /// Jumps to a queued track, like clicking it in Spotify.
    func play(_ track: QueueTrack) {
        player.skip(times: track.skips)
    }

    // MARK: - Private

    private func trackChanged(to trackID: String?) {
        // Shift the list right away instead of waiting for the Web API: a stale list would show the
        // new track twice, and clicking a row would skip by the wrong amount.
        if let trackID, let index = upcoming.firstIndex(where: { $0.uri == trackID }) {
            upcoming = Self.numbered(upcoming.dropFirst(index + 1))
        } else {
            upcoming = []
        }
        // The Web API lags behind the desktop client a little.
        reload(delay: .milliseconds(800))
    }

    private func load(attempt: Int = 1) async {
        if upcoming.isEmpty { state = .loading }
        do {
            let response = try await api.queue()
            guard !Task.isCancelled else { return }

            // The Web API may still report the previous track; that list would be off by one.
            if let current = player.track?.id, let reported = response.currentlyPlaying?.uri, reported != current {
                if attempt < 4 {
                    try await Task.sleep(for: .seconds(1))
                    await load(attempt: attempt + 1)
                }
                return
            }

            upcoming = Self.numbered(response.queue.map { track in
                QueueTrack(
                    id: "",
                    uri: track.uri,
                    title: track.name,
                    artist: track.artistLine,
                    artworkURL: track.thumbnailURL(),
                    duration: Double(track.durationMs ?? 0) / 1000,
                    skips: 0
                )
            })
            state = .loaded
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch SpotifyAPIError.notSignedIn {
            state = .signedOut
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Assigns ids and skip counts by position in the queue.
    private static func numbered<S: Sequence>(_ tracks: S) -> [QueueTrack] where S.Element == QueueTrack {
        tracks.enumerated().map { index, track in
            QueueTrack(
                id: "upcoming-\(index):\(track.uri)",
                uri: track.uri,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL,
                duration: track.duration,
                skips: index + 1
            )
        }
    }
}
