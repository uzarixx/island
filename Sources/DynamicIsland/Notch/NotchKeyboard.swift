import AppKit
import Carbon.HIToolbox

/// Keyboard control of the expanded notch. Keys are matched by physical key code, so they work
/// the same with a Russian layout ("L" is the key labelled Д too).
///
/// Everywhere: digits or ⌘-digits switch tabs, ⇥ / ⇧⇥ go to the next / previous one, Esc closes.
/// Music: space plays/pauses, ← → change the track, ↑ ↓ the volume, L likes the track, / searches.
/// Chats, links, clipboard: ← → pick, ↩ opens / copies, N adds; ⌫ removes from the clipboard.
/// Meetings: ↑ ↓ pick, ↩ joins, N adds.
/// Shelf: ← → pick, space previews with Quick Look, ↩ opens, ⌫ takes off the shelf.
@MainActor
final class NotchKeyboard {
    private let viewModel: NotchViewModel
    private let spotify: SpotifyController
    private let chats: ChatStore
    private let links: LinkStore
    private let meetings: MeetingStore
    private let clipboard: ClipboardStore
    private let shelf: ShelfStore
    private let close: () -> Void

    private static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    init(
        viewModel: NotchViewModel,
        spotify: SpotifyController,
        chats: ChatStore,
        links: LinkStore,
        meetings: MeetingStore,
        clipboard: ClipboardStore,
        shelf: ShelfStore,
        close: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.spotify = spotify
        self.chats = chats
        self.links = links
        self.meetings = meetings
        self.clipboard = clipboard
        self.shelf = shelf
        self.close = close
    }

    /// Returns true if the key was used; otherwise it goes on to the focused view.
    func handle(_ event: NSEvent) -> Bool {
        let key = Int(event.keyCode)
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        if let alarm = meetings.activeAlarm {
            switch key {
            case kVK_Return, kVK_ANSI_KeypadEnter: meetings.join(alarm.meeting)
            case kVK_Escape: meetings.dismissAlarm()
            default: return false
            }
            return true
        }

        // ⌘-digits aren't typing, so they switch tabs even from a text field.
        if modifiers == .command, let tab = tab(for: key) {
            select(tab)
            return true
        }

        if viewModel.isEditing {
            // The add forms cancel on Esc themselves; the notes editor has nothing to cancel.
            if key == kVK_Escape, viewModel.selectedTab == .notes {
                close()
                return true
            }
            return false
        }

        if key == kVK_Tab, modifiers.isSubset(of: .shift) {
            cycleTab(by: modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        guard modifiers.isEmpty else { return false }

        if key == kVK_Escape {
            close()
            return true
        }
        if let tab = tab(for: key) {
            select(tab)
            return true
        }
        switch viewModel.selectedTab {
        case .music: return handleMusic(key)
        case .chats: return handleGrid(key, items: chats.items, open: chats.open)
        case .links: return handleGrid(key, items: links.items, open: links.open)
        case .meetings: return handleMeetings(key)
        case .clipboard: return handleClipboard(key)
        case .shelf: return handleShelf(key)
        case .notes, .battery: return false
        }
    }

    // MARK: - Tabs

    private func handleMusic(_ key: Int) -> Bool {
        switch key {
        case kVK_Space: spotify.playPause()
        case kVK_LeftArrow: spotify.previousTrack()
        case kVK_RightArrow: spotify.nextTrack()
        case kVK_UpArrow: spotify.setVolume(spotify.volume + 10)
        case kVK_DownArrow: spotify.setVolume(spotify.volume - 10)
        case kVK_ANSI_L: spotify.toggleLike()
        case kVK_ANSI_Slash:
            // The search pane focuses its field once the notch takes typing.
            UserDefaults.standard.set(MusicPane.search.rawValue, forKey: MusicPane.defaultsKey)
            DispatchQueue.main.async { self.viewModel.isEditing = true }
        default: return false
        }
        return true
    }

    private func handleGrid<Item>(_ key: Int, items: [Item], open: (Item) -> Void) -> Bool {
        switch key {
        case kVK_LeftArrow: moveSelection(by: -1, count: items.count)
        case kVK_RightArrow: moveSelection(by: 1, count: items.count)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let item = selected(in: items) else { return false }
            open(item)
            close()
        case kVK_ANSI_N: viewModel.isEditing = true
        default: return false
        }
        return true
    }

    private func handleMeetings(_ key: Int) -> Bool {
        let items = meetings.upcoming().map(\.meeting)
        switch key {
        case kVK_UpArrow, kVK_LeftArrow: moveSelection(by: -1, count: items.count)
        case kVK_DownArrow, kVK_RightArrow: moveSelection(by: 1, count: items.count)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let meeting = selected(in: items), meeting.url != nil else { return false }
            meetings.join(meeting)
            close()
        case kVK_ANSI_N: viewModel.isEditing = true
        default: return false
        }
        return true
    }

    private func handleClipboard(_ key: Int) -> Bool {
        let items = clipboard.items
        switch key {
        case kVK_LeftArrow: moveSelection(by: -1, count: items.count)
        case kVK_RightArrow: moveSelection(by: 1, count: items.count)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Copy and get out of the way, so ⌘V goes to the app you were in.
            guard let item = selected(in: items) else { return false }
            clipboard.copy(item)
            close()
        case kVK_Delete, kVK_ForwardDelete:
            guard let item = selected(in: items) else { return false }
            clipboard.remove(item)
            let remaining = clipboard.items.count
            viewModel.keyboardSelection = remaining == 0 ? nil : min(viewModel.keyboardSelection ?? 0, remaining - 1)
        default: return false
        }
        return true
    }

    private func handleShelf(_ key: Int) -> Bool {
        let items = shelf.items
        switch key {
        case kVK_LeftArrow: moveSelection(by: -1, count: items.count)
        case kVK_RightArrow: moveSelection(by: 1, count: items.count)
        case kVK_Space:
            guard let item = selected(in: items) ?? items.first else { return false }
            shelf.quickLook(item)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let item = selected(in: items) else { return false }
            shelf.open(item)
            close()
        case kVK_Delete, kVK_ForwardDelete:
            guard let item = selected(in: items) else { return false }
            shelf.remove(item)
            let remaining = shelf.items.count
            viewModel.keyboardSelection = remaining == 0 ? nil : min(viewModel.keyboardSelection ?? 0, remaining - 1)
        default: return false
        }
        return true
    }

    // MARK: - Helpers

    private func tab(for key: Int) -> NotchTab? {
        guard let index = Self.digitKeys.firstIndex(of: key), viewModel.tabs.indices.contains(index) else { return nil }
        return viewModel.tabs[index]
    }

    private func select(_ tab: NotchTab) {
        guard tab != viewModel.selectedTab else { return }
        viewModel.selectedTab = tab
    }

    private func cycleTab(by step: Int) {
        let tabs = viewModel.tabs
        let index = tabs.firstIndex(of: viewModel.selectedTab) ?? 0
        select(tabs[(index + step + tabs.count) % tabs.count])
    }

    /// The first arrow press picks the first item.
    private func moveSelection(by step: Int, count: Int) {
        guard count > 0 else { return }
        viewModel.keyboardSelection = viewModel.keyboardSelection.map { min(max($0 + step, 0), count - 1) } ?? 0
    }

    private func selected<Item>(in items: [Item]) -> Item? {
        viewModel.keyboardSelection.flatMap { items.indices.contains($0) ? items[$0] : nil }
    }
}
