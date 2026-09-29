import SwiftUI

private struct CloseNotchKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Collapses the notch: opening a chat, a link or a meeting leaves the island out of the way.
    var closeNotch: () -> Void {
        get { self[CloseNotchKey.self] }
        set { self[CloseNotchKey.self] = newValue }
    }
}

struct NotchView: View {
    @ObservedObject var viewModel: NotchViewModel
    // Observed here: the live activity and the alarm take over the whole notch.
    @ObservedObject private var player: PlayerController
    /// Signing in to Spotify brings the queue and playlists next to the player.
    @ObservedObject private var auth: SpotifyAuth
    @ObservedObject private var meetings: MeetingStore
    private let queue: QueueController
    private let library: LibraryController
    private let chats: ChatStore
    private let links: LinkStore
    private let clipboard: ClipboardStore
    private let shelf: ShelfStore
    private let notes: NoteStore
    private let recorder: VoiceRecorder
    private let batt: BattController
    /// Collapses the notch, e.g. after opening a chat or a link.
    private let close: () -> Void
    private let openSettings: () -> Void

    init(viewModel: NotchViewModel, model: AppModel, close: @escaping () -> Void, openSettings: @escaping () -> Void) {
        self.viewModel = viewModel
        _player = ObservedObject(wrappedValue: model.player)
        _auth = ObservedObject(wrappedValue: model.auth)
        _meetings = ObservedObject(wrappedValue: model.meetings)
        queue = model.queue
        library = model.library
        chats = model.chats
        links = model.links
        clipboard = model.clipboard
        shelf = model.shelf
        notes = model.notes
        recorder = model.recorder
        batt = model.batt
        self.close = close
        self.openSettings = openSettings
    }

    var body: some View {
        let size = viewModel.currentSize
        let shape = NotchShape(
            topRadius: viewModel.ear,
            bottomRadius: viewModel.isExpanded ? 28 : 10
        )

        let expanded = viewModel.isExpanded

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            content
        }
        .animation(NotchViewModel.heightAnimation(expanded: expanded)) { $0.frame(height: size.height) }
        .animation(NotchViewModel.widthAnimation(expanded: expanded)) { $0.frame(width: size.width) }
        .clipShape(shape)
        .shadow(color: .black.opacity(viewModel.isExpanded ? 0.55 : 0), radius: 14, y: 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // The panel takes the keyboard only when asked (it would steal typing from the app the
        // user is in), so it's rarely key. Draw it as active anyway: inactive, Liquid Glass and
        // controls go flat and grey until the first click.
        .environment(\.controlActiveState, .key)
        .environment(\.closeNotch, close)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isExpanded {
            ZStack(alignment: .topTrailing) {
                expandedContent
                    .padding(.top, viewModel.notchSize.height + 6)
                    .padding(.horizontal, viewModel.expandedEar + 12)
                    .padding(.bottom, 14)

                // Beside the camera: the volume on the left while it's changed with a scroll there,
                // a battery flash (charger connected, low battery) on the right.
                HStack(spacing: 10) {
                    ZStack {
                        if let volume = viewModel.volumeFeedback {
                            VolumeIndicator(volume: volume, colors: player.artworkColors)
                                .transition(.blurred(radius: 6, scale: 0.7, anchor: .trailing))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    Color.clear.frame(width: viewModel.notchSize.width)
                    ZStack {
                        if let battery = viewModel.batteryFlash {
                            HStack(spacing: 6) {
                                BatteryGlyph(event: battery)
                                BatteryPercent(event: battery)
                            }
                            .transition(.blurred(radius: 6, scale: 0.7, anchor: .leading))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: viewModel.notchSize.height)
                .allowsHitTesting(false)

                // In the empty strip to the right of the physical notch.
                if meetings.activeAlarm == nil {
                    IconButton(icon: "gearshape.fill", title: L("Настройки", "Settings"), isSelected: false, action: openSettings)
                        .padding(.top, max(0, (viewModel.notchSize.height - 28) / 2))
                        .padding(.trailing, viewModel.expandedEar + 12)
                }
            }
            // Content comes into focus once the shape has started to grow, and blurs away quickly on close.
            .transition(.asymmetric(
                    insertion: .blurred(radius: 14, scale: 0.92, anchor: .top)
                        .animation(.spring(duration: 0.42, bounce: 0.15).delay(0.1)),
                    removal: .blurred(radius: 10, scale: 0.96, anchor: .top)
                        .animation(.easeIn(duration: 0.14))
                ))
        } else if let activity = viewModel.collapsedActivity {
            CollapsedActivityView(activity: activity, player: player, sideWidth: viewModel.activitySideWidth)
                // One activity replacing another (a charging flash over the music) blurs into it
                // while the shape springs to the new width.
                .id(activity.kind)
                .padding(.horizontal, viewModel.collapsedEar)
                .frame(height: viewModel.notchSize.height)
                .transition(.asymmetric(
                    insertion: .blurred(radius: 8, scale: 0.6, anchor: .center)
                        .animation(.spring(duration: 0.4, bounce: 0.3).delay(0.08)),
                    removal: .blurred(radius: 8, scale: 0.8, anchor: .center)
                        .animation(.easeIn(duration: 0.15))
                ))
        }
    }

    /// Navigation on the left, the selected tab on the right; a ringing meeting alarm takes over.
    @ViewBuilder
    private var expandedContent: some View {
        if let alarm = meetings.activeAlarm {
            MeetingAlarmView(
                alarm: alarm,
                join: { meetings.join(alarm.meeting) },
                dismiss: meetings.dismissAlarm
            )
        } else {
            HStack(spacing: 12) {
                NavigationRail(selection: $viewModel.selectedTab, tabs: viewModel.tabs)
                    // Switching tabs abandons an unfinished form.
                    .onChange(of: viewModel.selectedTab) { viewModel.isEditing = false }
                separator
                selectedTabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The music tab is two panes (player and queue) with Spotify connected, just the player
    /// otherwise; the others fill the width.
    @ViewBuilder
    private var selectedTabContent: some View {
        switch viewModel.selectedTab {
        case .music:
            if player.hasLibrary {
                HStack(spacing: 12) {
                    PlayerView(player: player)
                        .frame(width: 300)
                    separator
                    MusicBrowserView(queue: queue, library: library, player: player, isEditing: $viewModel.isEditing, openSettings: openSettings)
                }
            } else {
                PlayerView(player: player, isWide: true)
                    .frame(maxWidth: 480)
            }
        case .shelf:
            ShelfView(store: shelf, selection: viewModel.keyboardSelection)
        case .chats:
            ChatsView(chats: chats, isEditing: $viewModel.isEditing, selection: viewModel.keyboardSelection)
        case .links:
            LinksView(links: links, isAdding: $viewModel.isEditing, selection: viewModel.keyboardSelection)
        case .meetings:
            MeetingsView(store: meetings, calendar: meetings.calendar, isEditing: $viewModel.isEditing, selection: viewModel.keyboardSelection)
        case .clipboard:
            ClipboardView(store: clipboard, selection: viewModel.keyboardSelection)
        case .notes:
            NotesView(store: notes, recorder: recorder, isEditing: $viewModel.isEditing, autoFocus: viewModel.isKeyboardOpened)
        case .battery:
            BatteryView(batt: batt, isEditing: $viewModel.isEditing)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1)
    }
}

/// Blur, fade and scale together: how content comes and goes on the iPhone's Dynamic Island.
private struct BlurredModifier: ViewModifier {
    let radius: CGFloat
    let scale: CGFloat
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .blur(radius: radius)
            .scaleEffect(scale, anchor: anchor)
            .opacity(radius == 0 ? 1 : 0)
    }
}

extension AnyTransition {
    static func blurred(radius: CGFloat, scale: CGFloat, anchor: UnitPoint) -> AnyTransition {
        .modifier(
            active: BlurredModifier(radius: radius, scale: scale, anchor: anchor),
            identity: BlurredModifier(radius: 0, scale: 1, anchor: anchor)
        )
    }
}
