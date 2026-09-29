import AppKit
import Carbon.HIToolbox

/// A key with modifiers, as Carbon's hot key API takes it.
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (`cmdKey`, `optionKey`, ...).
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags
        var carbon = 0
        if flags.contains(.control) { carbon |= controlKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.command) { carbon |= cmdKey }
        modifiers = UInt32(carbon)
    }

    /// Needs ⌃, ⌥ or ⌘ (⇧ alone would take over a normal character), except for F-keys.
    var isValidGlobalShortcut: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 || Self.functionKeys.contains(Int(keyCode))
    }

    /// "⌃⌥Пробел", in the order macOS menus use.
    var description: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(Int(keyCode))
    }

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
    ]

    private static let specialNames: [Int: String] = [
        kVK_Space: L("Пробел", "Space"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// The key's label in the Latin layout, so "C" doesn't show as "С" with a Russian layout on.
    private static func keyName(_ keyCode: Int) -> String {
        if let special = specialNames[keyCode] { return special }
        if let index = functionKeys.firstIndex(of: keyCode) { return "F\(index + 1)" }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return "#\(keyCode)" }

        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// A system-wide shortcut. Carbon's hot keys, unlike a global NSEvent key monitor,
/// need no Accessibility permission. Unregistered when released.
final class GlobalHotKey {
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Fails if the shortcut can't be registered, e.g. another app already took it.
    init?(_ combo: KeyCombo, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.action = action

        // Every hot key's handler sees every hot key event; each one answers only to its own id.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed
            )
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            guard status == noErr, pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            hotKey.action()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x444E_4953), id: id) // "DNIS"
        guard RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
