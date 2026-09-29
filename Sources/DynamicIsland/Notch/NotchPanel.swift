import AppKit

/// Borderless transparent panel that sits above the menu bar, over the notch.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    /// Only the open notch takes the keyboard. When the panel gives it away, AppKit looks for
    /// another window of ours to make key; a collapsed notch that accepted would keep swallowing
    /// every key press (with an error beep) in the app the user went back to.
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// The app never becomes active while typing in the notch, so the Edit menu's shortcuts
    /// may not reach the text field. Handle the basic ones here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command || modifiers == [.command, .shift] {
            let action: Selector? = switch (event.charactersIgnoringModifiers?.lowercased(), modifiers.contains(.shift)) {
            case ("v", false): #selector(NSText.paste(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("x", false): #selector(NSText.cut(_:))
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            default: nil
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Don't let AppKit push the window below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Invisible panel used to give the keyboard back: it becomes key for a moment and is ordered
/// out, and key status returns to the app the user was working in (the notch never activates
/// ours). Hiding and showing the notch panel itself would do the same but make it blink.
final class KeyHandoffPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        alphaValue = 0
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
