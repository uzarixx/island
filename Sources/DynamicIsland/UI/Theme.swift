import SwiftUI

extension Color {
    /// The app's accent: Spotify's green, used across the notch for "on", "copied" and actions.
    static let notchGreen = Color(red: 0.12, green: 0.84, blue: 0.38)
}

extension Locale {
    /// Dates in the interface's language (see `AppLanguage`), whatever the system region.
    static let app = AppLanguage.current.locale
}

/// "3:07" from seconds.
func formatTime(_ seconds: Double) -> String {
    let total = Int(seconds.rounded(.down))
    return String(format: "%d:%02d", total / 60, total % 60)
}
