import Foundation
import NaturalLanguage
import SwiftUI
import Translation

/// Text to translate: into the interface language, or, if the text already is in it, into the
/// other of Russian and English (Russian interface: ru → en; English interface: en → ru).
struct TranslationRequest: Equatable {
    let id = UUID()
    let text: String
    /// Language codes like "en"; the source is nil when it can't be told from the text.
    let source: String?
    let target: String

    init(text: String) {
        self.text = text
        let detected = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        source = detected
        let interface = AppLanguage.current.code
        target = detected == interface ? (interface == "ru" ? "en" : "ru") : interface
    }

    /// "английский → русский" / "English → Russian", in the interface language.
    var languagesDescription: String {
        let names = [source, target].compactMap { $0 }.map { Locale.app.localizedString(forLanguageCode: $0) ?? $0 }
        return names.joined(separator: " → ")
    }
}

/// Translation runs on the device with Apple's Translation framework (macOS 15+).
enum ClipboardTranslation {
    enum Readiness {
        case ready
        /// The languages are supported but not downloaded yet.
        case needsDownload
        case unsupported
    }

    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { true } else { false }
    }

    /// Checked first: the framework's own download prompt is a sheet, which the notch can't host.
    static func readiness(for request: TranslationRequest) async -> Readiness {
        guard #available(macOS 15.0, *) else { return .unsupported }
        guard let source = request.source else { return .ready }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source),
            to: Locale.Language(identifier: request.target)
        )
        switch status {
        case .installed: return .ready
        case .supported: return .needsDownload
        default: return .unsupported
        }
    }

    /// System Settings → General → Language & Region, where "Translation Languages" are downloaded.
    static func openLanguageSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

extension View {
    /// Runs `request` through a translation session attached to this view; does nothing before macOS 15.
    @ViewBuilder
    func translating(_ request: TranslationRequest?, finish: @escaping (TranslationRequest, String?) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            modifier(TranslationRunner(request: request, finish: finish))
        } else {
            self
        }
    }
}

@available(macOS 15.0, *)
private struct TranslationRunner: ViewModifier {
    let request: TranslationRequest?
    /// Called with the translation, or nil if it failed.
    let finish: (TranslationRequest, String?) -> Void

    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            // Runs whenever the configuration is set or invalidated.
            .translationTask(configuration) { session in
                guard let request else { return }
                let response = try? await session.translate(request.text)
                finish(request, response?.targetText)
            }
            .onChange(of: request) {
                guard let request else { return }
                let source = request.source.map { Locale.Language(identifier: $0) }
                let target = Locale.Language(identifier: request.target)
                if configuration?.source == source, configuration?.target == target {
                    // Same languages as last time: invalidating runs the task again.
                    configuration?.invalidate()
                } else {
                    configuration = TranslationSession.Configuration(source: source, target: target)
                }
            }
    }
}
