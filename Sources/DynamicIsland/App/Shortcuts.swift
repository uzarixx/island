import AppKit
import Carbon.HIToolbox

/// What a global shortcut does. Each one is set in Settings.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case toggleNotch, pickColor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleNotch: L("Открыть остров", "Open the island")
        case .pickColor: L("Пипетка: взять цвет с экрана", "Color picker: pick a color from the screen")
        }
    }

    /// ⌃⌥ keeps clear of the usual ones: ⌥Space is often Raycast or Alfred, ⌃Space switches the language.
    var defaultCombo: KeyCombo {
        switch self {
        case .toggleNotch: KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey))
        case .pickColor: KeyCombo(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(controlKey | optionKey))
        }
    }

    fileprivate var defaultsKey: String { "shortcut.\(rawValue)" }
}

/// Keeps the global shortcuts registered as they're changed in Settings.
@MainActor
final class ShortcutCenter: ObservableObject {
    static let shared = ShortcutCenter()

    /// nil: switched off.
    @Published private(set) var combos: [ShortcutAction: KeyCombo?] = [:]
    /// Shortcuts that couldn't be registered, most likely because another app uses them.
    @Published private(set) var unavailable: Set<ShortcutAction> = []

    private var handlers: [ShortcutAction: () -> Void] = [:]
    private var hotKeys: [ShortcutAction: GlobalHotKey] = [:]
    /// While a shortcut is being recorded, so pressing the current one records it instead of firing.
    private var isPaused = false

    private init() {
        Self.migrateOldSetting()
        for action in ShortcutAction.allCases {
            combos[action] = Self.load(action)
        }
    }

    func combo(for action: ShortcutAction) -> KeyCombo? {
        combos[action] ?? nil
    }

    func setHandler(for action: ShortcutAction, _ handler: @escaping () -> Void) {
        handlers[action] = handler
        register(action)
    }

    func setCombo(_ combo: KeyCombo?, for action: ShortcutAction) {
        combos[action] = .some(combo)
        let data = try? JSONEncoder().encode(combo)
        UserDefaults.standard.set(data, forKey: action.defaultsKey)
        register(action)
    }

    /// The other action already using `combo`, if any.
    func conflict(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self.combo(for: $0) == combo }
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        ShortcutAction.allCases.forEach(register)
    }

    private func register(_ action: ShortcutAction) {
        hotKeys[action] = nil
        unavailable.remove(action)
        guard !isPaused, let combo = combo(for: action), let handler = handlers[action] else { return }
        if let hotKey = GlobalHotKey(combo, action: handler) {
            hotKeys[action] = hotKey
        } else {
            unavailable.insert(action)
        }
    }

    /// A stored `null` means switched off; nothing stored means the default.
    private static func load(_ action: ShortcutAction) -> KeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else { return action.defaultCombo }
        // Not `try?`: it would flatten "switched off" into "unreadable" and bring the default back.
        do {
            return try JSONDecoder().decode(KeyCombo?.self, from: data)
        } catch {
            return action.defaultCombo
        }
    }

    /// Earlier versions offered a few fixed shortcuts for opening the notch.
    private static func migrateOldSetting() {
        let oldKey = "hotKey"
        guard let old = UserDefaults.standard.string(forKey: oldKey) else { return }
        UserDefaults.standard.removeObject(forKey: oldKey)
        let combo: KeyCombo? = switch old {
        case "optionSpace": KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        case "optionGrave": KeyCombo(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey))
        case "off": nil
        default: ShortcutAction.toggleNotch.defaultCombo
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(combo), forKey: ShortcutAction.toggleNotch.defaultsKey)
    }
}
