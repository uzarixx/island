import AppKit

enum AppSettings {
    static let hideFromScreenCaptureKey = "hideFromScreenCapture"
    static let clipboardHistoryKey = "clipboardHistoryEnabled"
    /// The stored name is from when the gestures worked on the collapsed notch; kept for existing settings.
    static let cameraGesturesKey = "collapsedGesturesEnabled"
    static let middleClickKey = "middleClickEnabled"
    static let middleClickTapKey = "middleClickTapEnabled"
    static let liveEqualizerKey = "liveEqualizerEnabled"

    static var clipboardHistoryEnabled: Bool {
        UserDefaults.standard.object(forKey: clipboardHistoryKey) as? Bool ?? true
    }

    static var hideFromScreenCapture: Bool {
        UserDefaults.standard.object(forKey: hideFromScreenCaptureKey) as? Bool ?? true
    }

    /// Scrolling on the strip level with the camera controls Spotify.
    static var cameraGesturesEnabled: Bool {
        UserDefaults.standard.object(forKey: cameraGesturesKey) as? Bool ?? true
    }

    /// Three fingers on the trackpad make a middle click; on by default.
    static var middleClickEnabled: Bool {
        UserDefaults.standard.object(forKey: middleClickKey) as? Bool ?? true
    }

    /// A light three-finger tap counts too, not only a click; on by default, like in MiddleClick.
    static var middleClickTapEnabled: Bool {
        UserDefaults.standard.object(forKey: middleClickTapKey) as? Bool ?? true
    }

    /// The equalizer follows Spotify's real sound. Off by default: capturing it needs permission
    /// and makes macOS show its purple recording dot while music plays.
    static var liveEqualizerEnabled: Bool {
        UserDefaults.standard.object(forKey: liveEqualizerKey) as? Bool ?? false
    }

    /// Where the app keeps its files: notes, the Spotify token, a custom alarm sound.
    static var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "DynamicIsland")
    }

    /// `.none` excludes the window from screenshots, recordings and screen sharing.
    static var windowSharingType: NSWindow.SharingType {
        hideFromScreenCapture ? .none : .readOnly
    }
}
