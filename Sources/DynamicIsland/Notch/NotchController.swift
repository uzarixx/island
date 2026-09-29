import AppKit
import Combine
import SwiftUI

/// Runs the notch window: where it sits, when it opens and closes (hover, clicks, the keyboard,
/// a ringing alarm), the keyboard inside it, the scroll gestures, and the short flashes on the
/// collapsed notch.
@MainActor
final class NotchController {
    let viewModel = NotchViewModel()

    private let model: AppModel
    private let panel = NotchPanel()
    private let keyHandoff = KeyHandoffPanel()
    private lazy var keyboard = NotchKeyboard(
        viewModel: viewModel,
        spotify: model.spotify,
        chats: model.chats,
        links: model.links,
        meetings: model.meetings,
        clipboard: model.clipboard,
        shelf: model.shelf,
        close: { [weak self] in self?.setExpanded(false) }
    )
    private lazy var gestures = NotchGestures(spotify: model.spotify) { [weak self] volume in
        self?.showVolumeFeedback(volume)
    }
    private var powerMonitor: PowerMonitor?
    private var eventMonitors: [Any] = []
    private var dragPollTimer: Timer?
    private var collapseTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var volumeFeedbackTask: Task<Void, Never>?
    /// Hides each flash (charging, picked color) a while after it was shown.
    private var flashTasks: [PartialKeyPath<NotchViewModel>: Task<Void, Never>] = [:]
    /// The eyedropper is on screen: moving over the notch mustn't open it.
    private var isPickingColor = false
    /// The drag pasteboard's change count when the mouse last went down, and whether that was in
    /// the notch: a new count while the button is held means another app is dragging something.
    private var dragPasteboardCount = NSPasteboard(name: .drag).changeCount
    private var isMouseDownInNotch = false
    /// The drag that already switched the notch to the shelf, so it does so once.
    private var shelfSwitchCount: Int?
    private var cancellables = Set<AnyCancellable>()

    private static let collapseDelay: Duration = .milliseconds(400)
    /// The cursor has to rest on the notch this long: passing by on the way to the menu bar
    /// doesn't open it.
    private static let openDelay: Duration = .milliseconds(300)
    /// A drag opens the notch sooner: holding it at the top edge of the screen would enter
    /// Mission Control.
    private static let dragOpenDelay: Duration = .milliseconds(120)
    /// How far below the notch a drag already opens it.
    private static let dragReach: CGFloat = 90

    init(model: AppModel, openSettings: @escaping () -> Void) {
        self.model = model
        let rootView = NotchView(
            viewModel: viewModel,
            model: model,
            close: { [weak self] in self?.setExpanded(false) },
            openSettings: openSettings
        )
        let hostingView = FirstMouseHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.sharingType = AppSettings.windowSharingType
        layout()
        panel.orderFrontRegardless()

        setupMouseTracking()
        setupKeyboard()
        observeModel()
    }

    // MARK: - Public

    func collapse() {
        setExpanded(false)
    }

    /// Opens the notch with the keyboard in it; closes it if it already has the keyboard.
    func toggleFromKeyboard() {
        if viewModel.isExpanded && panel.isKeyWindow {
            setExpanded(false)
            return
        }
        // Before expanding: the notes tab focuses its editor when it appears.
        viewModel.isKeyboardOpened = true
        setExpanded(true)
        panel.makeKey()
    }

    /// Closes the notch, lets the user pick a color anywhere on screen, and copies its hex code.
    func pickColor() {
        guard !isPickingColor else { return }
        isPickingColor = true
        // An open notch closes first and gives the keyboard back (see `setExpanded`), so neither
        // gets in the way of the eyedropper.
        let delay = viewModel.isExpanded ? 0.6 : 0
        setExpanded(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            ColorPicker.pick { picked in
                guard let self else { return }
                self.isPickingColor = false
                guard let picked else { return }
                self.model.clipboard.addCopiedText(picked.hex)
                self.flash(\.colorFlash, picked, for: .seconds(2.5))
            }
        }
    }

    func setSharingType(_ sharingType: NSWindow.SharingType) {
        if panel.sharingType != sharingType { panel.sharingType = sharingType }
    }

    /// Over the notch of the built-in display, sized for the expanded state; call when screens change.
    func layout() {
        guard let screen = targetScreen else { return }
        viewModel.update(for: screen)
        let size = viewModel.windowSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }

    // MARK: - Model

    private func observeModel() {
        let spotify = model.spotify
        spotify.$isPlaying
            .combineLatest(spotify.$track)
            .map { isPlaying, track in isPlaying && track != nil }
            .removeDuplicates()
            .sink { [weak self] active in
                withAnimation(NotchViewModel.animation) { self?.viewModel.hasLiveActivity = active }
                // The equalizer can follow the real sound only while there is some.
                AudioLevelMeter.shared.setPlaying(active)
            }
            .store(in: &cancellables)

        model.recorder.$recordingSince
            .removeDuplicates()
            .sink { [weak self] since in
                withAnimation(NotchViewModel.animation) { self?.viewModel.recordingSince = since }
            }
            .store(in: &cancellables)

        powerMonitor = PowerMonitor { [weak self] event in
            // A low battery stays up a bit longer: it asks for something to be done.
            let duration: Duration = if case .low = event { .seconds(6) } else { .seconds(3) }
            self?.flash(\.batteryFlash, event, for: duration)
        }

        TabSettings.shared.objectWillChange
            .sink { [weak self] _ in
                // objectWillChange fires before the change; read the new tabs on the next turn.
                DispatchQueue.main.async { self?.viewModel.updateTabs() }
            }
            .store(in: &cancellables)

        // The queue is only fetched while it's visible.
        viewModel.$isExpanded
            .combineLatest(viewModel.$selectedTab)
            .map { expanded, tab in expanded && tab == .music }
            .removeDuplicates()
            .sink { [weak self] visible in self?.model.queue.setActive(visible) }
            .store(in: &cancellables)

        // Typing into an add form needs the panel to be key. The keyboard is given back once the
        // notch has collapsed (see `setExpanded`), not when the form closes: the notch may still
        // need it, e.g. for keyboard navigation.
        viewModel.$isEditing
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in self?.panel.makeKey() }
            .store(in: &cancellables)

        // A ringing alarm opens the notch by itself and keeps it open until handled.
        model.meetings.$activeAlarm
            .map { $0 != nil }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] ringing in
                guard let self else { return }
                if ringing {
                    viewModel.isEditing = false
                    setExpanded(true)
                } else {
                    // Published fires before the value changes; check the mouse on the next turn.
                    DispatchQueue.main.async { self.updateHover() }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Flashes

    /// Shows something on the collapsed notch for a moment.
    private func flash<Value>(_ keyPath: ReferenceWritableKeyPath<NotchViewModel, Value?>, _ value: Value, for duration: Duration) {
        withAnimation(NotchViewModel.animation) { viewModel[keyPath: keyPath] = value }
        flashTasks[keyPath]?.cancel()
        flashTasks[keyPath] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            withAnimation(NotchViewModel.animation) { self.viewModel[keyPath: keyPath] = nil }
        }
    }

    private func showVolumeFeedback(_ volume: Int) {
        // Animate only its appearance: re-animating every step of a gesture makes it jitter.
        if viewModel.volumeFeedback == nil {
            withAnimation(.easeOut(duration: 0.15)) { viewModel.volumeFeedback = volume }
        } else {
            viewModel.volumeFeedback = volume
        }
        volumeFeedbackTask?.cancel()
        volumeFeedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.viewModel.volumeFeedback = nil }
        }
    }

    // MARK: - Mouse

    private func setupMouseTracking() {
        // Mouse-up too: after dragging something out of the notch, decide right away whether to close.
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }) {
            eventMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        }) {
            eventMonitors.append(local)
        }

        // Scroll gestures on the strip level with the camera (see `NotchGestures`).
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return handled ? nil : event
        }) {
            eventMonitors.append(scroll)
        }

        // A global monitor only sees clicks in other apps, i.e. outside the notch.
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteMouseDown(inNotch: false)
                self?.clickedOutside()
            }
        }) {
            eventMonitors.append(outside)
        }
        if let inside = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.noteMouseDown(inNotch: true) }
            return event
        }) {
            eventMonitors.append(inside)
        }

        // While something is dragged from another app (a link from the browser), mouse events may
        // not reach the monitors above. Poll the cursor then, so the notch opens under the drag.
        dragPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard NSEvent.pressedMouseButtons & 1 != 0 else { return }
            MainActor.assumeIsolated { self?.updateHover() }
        }
    }

    private func noteMouseDown(inNotch: Bool) {
        dragPasteboardCount = NSPasteboard(name: .drag).changeCount
        isMouseDownInNotch = inNotch
    }

    /// Something is being dragged from another app right now (a file, a picture, a link).
    private var isDraggingIn: Bool {
        NSEvent.pressedMouseButtons & 1 != 0 && !isMouseDownInNotch
            && NSPasteboard(name: .drag).changeCount != dragPasteboardCount
    }

    /// Files or pictures are being dragged from another app right now.
    private var isDraggingFilesIn: Bool {
        guard isDraggingIn else { return false }
        let types = Set(NSPasteboard(name: .drag).types ?? [])
        return types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff)
    }

    /// Files dragged to the notch go to the shelf, whatever tab it was on: it opens (or turns)
    /// right there, ready for the drop.
    private func switchToShelfForDrag() {
        let count = NSPasteboard(name: .drag).changeCount
        guard shelfSwitchCount != count, viewModel.tabs.contains(.shelf), isDraggingFilesIn,
              !viewModel.isEditing, model.meetings.activeAlarm == nil
        else { return }
        shelfSwitchCount = count
        if viewModel.selectedTab != .shelf { viewModel.selectedTab = .shelf }
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard viewModel.isExpanded, let screen = targetScreen,
              viewModel.gestureRect(in: screen).contains(NSEvent.mouseLocation)
        else { return false }
        return gestures.handle(event)
    }

    private func clickedOutside() {
        // A ringing alarm stays until it's answered in the notch.
        guard viewModel.isExpanded, model.meetings.activeAlarm == nil else { return }
        viewModel.isEditing = false
        setExpanded(false)
    }

    // MARK: - Keyboard

    private func setupKeyboard() {
        // The panel gets key events only while it's the key window: opened with the shortcut,
        // typing into a form, or after a click in it.
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }) {
            eventMonitors.append(keys)
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        viewModel.isExpanded && panel.isKeyWindow && keyboard.handle(event)
    }

    /// Gives key status to the app the user was working in again (the notch never activates the
    /// app, so that app stayed active), via an invisible panel so the notch doesn't blink:
    /// with music playing, its artwork and equalizer would flicker.
    private func releaseKeyboard() {
        guard panel.isKeyWindow, !viewModel.isExpanded else { return }
        keyHandoff.makeKeyAndOrderFront(nil)
        keyHandoff.orderOut(nil)
    }

    // MARK: - Opening and closing

    /// Prefer the built-in display with a notch, even if an external monitor is the main one.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    /// Where the cursor opens the collapsed notch: the notch itself, or during a drag a wider
    /// area reaching well below it, so the drag never has to go up to the screen edge, where
    /// macOS would enter Mission Control instead. The open notch is tall enough to drop onto.
    private func openRect(in screen: NSScreen) -> CGRect {
        let notch = viewModel.hitRect(in: screen)
        guard isDraggingIn else { return notch }
        let width = max(notch.width, viewModel.expandedSize.width * 0.6)
        let height = viewModel.notchSize.height + Self.dragReach
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height + 10)
    }

    private func updateHover() {
        guard let screen = targetScreen else { return }
        if viewModel.isExpanded {
            if openRect(in: screen).contains(NSEvent.mouseLocation) { switchToShelfForDrag() }
            if shouldStayOpen(in: screen) {
                cancelPendingCollapse()
            } else if collapseTask == nil {
                // Don't close the moment the cursor slips out; coming back in time keeps it open.
                collapseTask = Task { [weak self] in
                    try? await Task.sleep(for: Self.collapseDelay)
                    guard let self, !Task.isCancelled else { return }
                    collapseTask = nil
                    if !shouldStayOpen(in: screen) { setExpanded(false) }
                }
            }
        } else if openRect(in: screen).contains(NSEvent.mouseLocation), !isPickingColor {
            guard openTask == nil else { return }
            withAnimation(NotchViewModel.hoverAnimation) { viewModel.isHoverPrimed = true }
            let delay = isDraggingIn ? Self.dragOpenDelay : Self.openDelay
            openTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled else { return }
                openTask = nil
                if openRect(in: screen).contains(NSEvent.mouseLocation), !isPickingColor {
                    switchToShelfForDrag()
                    setExpanded(true)
                }
            }
        } else {
            cancelPendingOpen()
        }
    }

    private func cancelPendingOpen() {
        openTask?.cancel()
        openTask = nil
        if viewModel.isHoverPrimed {
            withAnimation(NotchViewModel.hoverAnimation) { viewModel.isHoverPrimed = false }
        }
    }

    private func shouldStayOpen(in screen: NSScreen) -> Bool {
        // Stay open while the button is held: dragging an image out, a tile to reorder, or a slider
        // past the edge. Closing would remove the view the drag started from and cancel it.
        // Also while an add form is open, the keyboard is in use or an alarm rings: moving the mouse
        // away mustn't lose them.
        let isMouseDown = NSEvent.pressedMouseButtons & 1 != 0
        let isPinned = viewModel.isEditing || viewModel.isKeyboardOpened || model.meetings.activeAlarm != nil
        let isInside = viewModel.hitRect(in: screen).insetBy(dx: -10, dy: -10).contains(NSEvent.mouseLocation)
        return isMouseDown || isPinned || isInside
    }

    private func cancelPendingCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func setExpanded(_ expanded: Bool) {
        cancelPendingCollapse()
        cancelPendingOpen()
        guard viewModel.isExpanded != expanded else { return }
        if expanded {
            // batt may have been installed or removed since last time.
            viewModel.setBatteryTabAvailable(BattController.isInstalled)
        } else {
            viewModel.isEditing = false
            viewModel.isKeyboardOpened = false
            viewModel.keyboardSelection = nil
        }
        withAnimation(expanded ? NotchViewModel.openAnimation : NotchViewModel.closeAnimation) {
            viewModel.isExpanded = expanded
        }
        // Collapsed notch must not swallow clicks aimed at the menu bar.
        panel.ignoresMouseEvents = !expanded
        model.spotify.setActive(expanded)
        if !expanded {
            // After the close animation: a form closing mid-animation would still take the keys.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.releaseKeyboard()
            }
        }
    }
}

/// Lets the first click on a button work even though the app is never active.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
