import AppKit

/// Scrolling on the strip level with the camera controls Spotify from any tab:
/// up / down changes the volume, a sideways swipe skips to the next or previous track.
@MainActor
final class NotchGestures {
    private let spotify: SpotifyController
    private let showVolume: (Int) -> Void

    private enum Axis {
        case undecided, horizontal, vertical
    }

    // State of the current trackpad gesture.
    private var axis = Axis.undecided
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var didSwipe = false

    /// Trackpad points per 1% of volume: fine steps feel smooth, and a long swipe still covers the range.
    private static let volumeStepDistance: CGFloat = 3
    private static let swipeDistance: CGFloat = 60

    init(spotify: SpotifyController, showVolume: @escaping (Int) -> Void) {
        self.spotify = spotify
        self.showVolume = showVolume
    }

    /// There's something to control.
    var isAvailable: Bool {
        AppSettings.cameraGesturesEnabled && spotify.isRunning && spotify.track != nil
    }

    /// Returns true if the event was taken as a gesture.
    func handle(_ event: NSEvent) -> Bool {
        guard isAvailable else { return false }
        // Inertia after the fingers lift would keep changing the volume.
        guard event.momentumPhase.isEmpty else { return true }

        // Positive means fingers (or the wheel) moving up / left, whatever the scroll direction setting.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        let dx = event.scrollingDeltaX * sign
        let dy = event.scrollingDeltaY * sign

        // A mouse wheel: each click is a volume step.
        guard event.hasPreciseScrollingDeltas else {
            guard dy != 0 else { return false }
            changeVolume(by: dy > 0 ? 5 : -5)
            return true
        }

        if event.phase == .began || event.phase == .mayBegin {
            axis = .undecided
            horizontal = 0
            vertical = 0
            didSwipe = false
        }
        horizontal += dx
        vertical += dy

        // Decide once per gesture, so a swipe doesn't nudge the volume on the way.
        if axis == .undecided, max(abs(horizontal), abs(vertical)) > 6 {
            axis = abs(horizontal) > abs(vertical) ? .horizontal : .vertical
        }
        switch axis {
        case .undecided:
            break
        case .horizontal:
            // One track per swipe, however long it is.
            if !didSwipe, abs(horizontal) > Self.swipeDistance {
                didSwipe = true
                // Swiping left moves on, like flicking a card away.
                if horizontal > 0 { spotify.nextTrack() } else { spotify.previousTrack() }
            }
        case .vertical:
            let steps = Int(vertical / Self.volumeStepDistance)
            if steps != 0 {
                vertical -= CGFloat(steps) * Self.volumeStepDistance
                changeVolume(by: steps)
            }
        }
        return true
    }

    private func changeVolume(by step: Int) {
        spotify.setVolume(spotify.volume + step)
        showVolume(spotify.volume)
    }
}
