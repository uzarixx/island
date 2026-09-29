import AppKit
import UniformTypeIdentifiers

/// The sound a meeting alarm plays: an iPhone-style ringtone (macOS ships the same set),
/// a short system alert sound, or the user's own file.
///
/// Stored as a string: "ringtone:Radar.m4r", "custom:song.mp3", or a system sound name like "Glass".
enum AlarmSound {
    static let settingKey = "alarmSound"

    private static let ringtonePrefix = "ringtone:"
    private static let customPrefix = "custom:"
    /// Variants with this suffix are the same tones; only one of each is listed.
    private static let variantSuffix = "-EncoreInfinitum"

    private static let ringtonesDirectory = URL(
        filePath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Resources/Ringtones"
    )
    private static var customDirectory: URL {
        AppSettings.dataDirectory.appending(path: "AlarmSound")
    }

    /// Radar, like the iPhone's default alarm; a system sound if the ringtones aren't there.
    static let defaultSetting: String = {
        let radar = "Radar.m4r"
        let exists = FileManager.default.fileExists(atPath: ringtonesDirectory.appending(path: radar).path)
        return exists ? ringtonePrefix + radar : "Glass"
    }()

    static var setting: String {
        UserDefaults.standard.string(forKey: settingKey) ?? defaultSetting
    }

    /// Ringtones as (setting, name), one per tone, sorted by name.
    static let ringtones: [(setting: String, name: String)] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: ringtonesDirectory.path)) ?? []
        var byName: [String: String] = [:]
        for file in files where file.hasSuffix(".m4r") {
            let name = toneName(file)
            // Prefer the plain file when both variants exist.
            if byName[name] == nil || !file.contains(variantSuffix) {
                byName[name] = file
            }
        }
        return byName.keys.sorted().map { (ringtonePrefix + byName[$0]!, $0) }
    }()

    /// Short alert sounds from /System/Library/Sounds and ~/Library/Sounds.
    static let systemNames: [String] = {
        let folders = [
            URL(filePath: "/System/Library/Sounds"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Sounds"),
        ]
        let names = folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        }
        .map { $0.deletingPathExtension().lastPathComponent }
        return Array(Set(names)).sorted()
    }()

    static func isCustom(_ setting: String) -> Bool {
        setting.hasPrefix(customPrefix)
    }

    static func isRingtone(_ setting: String) -> Bool {
        setting.hasPrefix(ringtonePrefix)
    }

    /// "Radar", "Glass", or the chosen file's name.
    static func displayName(_ setting: String) -> String {
        if isRingtone(setting) { return toneName(String(setting.dropFirst(ringtonePrefix.count))) }
        if isCustom(setting) { return String(setting.dropFirst(customPrefix.count)) }
        return setting
    }

    static func sound(for setting: String = setting) -> NSSound? {
        let sound: NSSound?
        if isRingtone(setting) {
            sound = NSSound(contentsOf: ringtonesDirectory.appending(path: String(setting.dropFirst(ringtonePrefix.count))), byReference: true)
        } else if isCustom(setting) {
            sound = NSSound(contentsOf: customDirectory.appending(path: displayName(setting)), byReference: false)
        } else {
            sound = NSSound(named: setting)
        }
        return sound ?? NSSound(named: "Glass")
    }

    /// Lets the user pick an audio file, copies it next to the app's data and returns the new setting.
    @MainActor
    static func chooseCustomFile() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = L("Выбери звук для будильника", "Choose an alarm sound")
        guard panel.runModal() == .OK, let source = panel.url else { return nil }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        let destination = customDirectory.appending(path: source.lastPathComponent)
        // Other meetings may use other custom files, so keep them; only replace one with the same name.
        try? fileManager.removeItem(at: destination)
        guard (try? fileManager.copyItem(at: source, to: destination)) != nil else { return nil }
        return customPrefix + source.lastPathComponent
    }

    private static func toneName(_ file: String) -> String {
        file.replacingOccurrences(of: ".m4r", with: "").replacingOccurrences(of: variantSuffix, with: "")
    }
}
