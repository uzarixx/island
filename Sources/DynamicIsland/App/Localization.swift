import AppKit

/// The interface language, fixed at launch: the one chosen in Settings, or by default Russian or
/// English, whichever comes first among the system's preferred languages (System Settings →
/// General → Language & Region); English for any other.
enum AppLanguage {
    case russian, english

    /// What Settings offers: follow the system, or one language.
    enum Choice: String, CaseIterable, Identifiable {
        case system, russian, english

        var id: String { rawValue }

        /// Language names are written in that language, as macOS does.
        var title: String {
            switch self {
            case .system: L("Как в системе", "System")
            case .russian: "Русский"
            case .english: "English"
            }
        }
    }

    static let choiceKey = "appLanguage"
    /// The choice when the app started, which `current` is made from.
    static let launchChoice = choice

    static var choice: Choice {
        get { UserDefaults.standard.string(forKey: choiceKey).flatMap(Choice.init) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: choiceKey)
            // Also for macOS itself: permission prompts and system panels follow AppleLanguages.
            switch newValue {
            case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .russian: UserDefaults.standard.set(["ru"], forKey: "AppleLanguages")
            case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            }
        }
    }

    /// Takes effect on the next launch: strings made at launch (menus, tables) stay as they are.
    static let current: AppLanguage = {
        switch choice {
        case .russian: return .russian
        case .english: return .english
        case .system: break
        }
        for identifier in Locale.preferredLanguages {
            switch Locale(identifier: identifier).language.languageCode?.identifier {
            case "ru": return .russian
            case "en": return .english
            default: continue
            }
        }
        return .english
    }()

    /// Quits and opens the app again, to switch the language.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        // The path goes in as $0, never into the command text.
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// "ru" / "en", for language-aware APIs like translation.
    var code: String {
        self == .russian ? "ru" : "en"
    }

    /// For dates and numbers: the system's region if it's in this language, so an English
    /// interface still gets British or Australian dates.
    var locale: Locale {
        if Locale.current.language.languageCode?.identifier == code { return .current }
        return Locale(identifier: self == .russian ? "ru_RU" : "en_US")
    }
}

/// Interface text in both languages, side by side: `L("Добавить", "Add")`.
func L(_ russian: String, _ english: String) -> String {
    AppLanguage.current == .russian ? russian : english
}

/// A count with its noun in the right form: `plural(3, "файл", "файла", "файлов", "file", "files")`
/// gives "3 файла" or "3 files".
func plural(_ count: Int, _ one: String, _ few: String, _ many: String, _ englishOne: String, _ englishOther: String) -> String {
    let word: String
    switch AppLanguage.current {
    case .russian:
        let lastTwo = abs(count) % 100, last = abs(count) % 10
        word = (11...14).contains(lastTwo) ? many : last == 1 ? one : (2...4).contains(last) ? few : many
    case .english:
        word = count == 1 ? englishOne : englishOther
    }
    return "\(count) \(word)"
}
