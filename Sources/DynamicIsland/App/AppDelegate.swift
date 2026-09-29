import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var notch: NotchController!
    private let meetingNotifications = MeetingNotifications()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        meetingNotifications.register()
        setupMainMenu()
        notch = NotchController(model: model, openSettings: { [weak self] in self?.openSettings() })
        setupShortcuts()
        MiddleClickEmulator.shared.apply()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.prepareForTermination()
    }

    // MARK: - Setup

    /// Never shown (the app has no Dock icon), but without it ⌘C/⌘V don't work in text fields.
    /// ⌘Q quits from the settings window: there's no menu bar icon to quit from.
    private func setupMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Завершить Island", "Quit Island"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupShortcuts() {
        let shortcuts = ShortcutCenter.shared
        // Carbon calls these on the main thread.
        shortcuts.setHandler(for: .toggleNotch) { [weak self] in
            MainActor.assumeIsolated { self?.notch.toggleFromKeyboard() }
        }
        shortcuts.setHandler(for: .pickColor) { [weak self] in
            MainActor.assumeIsolated { self?.notch.pickColor() }
        }
    }

    // MARK: - Settings

    private func openSettings() {
        notch.collapse()
        if settingsWindow == nil {
            // A hosting controller rather than a view: the sidebar and the pane titles live in the
            // window's toolbar, which only a controller hands over to SwiftUI.
            let root = SettingsView(auth: model.auth, chats: model.chats, links: model.links, calendar: model.meetings.calendar)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            // Like System Settings: the sidebar runs to the top, under the window buttons.
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.title = L("Island — настройки", "Island Settings")
            window.isReleasedWhenClosed = false
            window.sharingType = AppSettings.windowSharingType
            window.center()
            // The app has no other windows to type into: left active, every key press would beep.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                DispatchQueue.main.async { NSApp.deactivate() }
            }
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func settingsChanged() {
        let sharingType = AppSettings.windowSharingType
        notch.setSharingType(sharingType)
        if let settingsWindow, settingsWindow.sharingType != sharingType { settingsWindow.sharingType = sharingType }
        MiddleClickEmulator.shared.apply()
        AudioLevelMeter.shared.apply()
    }

    @objc private func screenParametersChanged() {
        notch.layout()
    }
}
