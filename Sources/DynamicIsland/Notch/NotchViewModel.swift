import AppKit
import SwiftUI

/// What the collapsed notch shows on the sides of the camera, most important first.
enum CollapsedActivity: Equatable {
    case recording(since: Date)
    case pickedColor(PickedColor)
    case battery(BatteryEvent)
    case music

    /// Changes when the kind of activity does, for the cross-fade between them.
    var kind: String {
        switch self {
        case .recording: "recording"
        case .pickedColor: "color"
        case .battery: "battery"
        case .music: "music"
        }
    }
}

@MainActor
final class NotchViewModel: ObservableObject {
    static let animation = Animation.spring(duration: 0.5, bounce: 0.15)
    /// Opening gets a slight bounce; closing settles without one and a bit faster.
    static let openAnimation = Animation.spring(duration: 0.5, bounce: 0.18)
    static let closeAnimation = Animation.spring(duration: 0.42, bounce: 0)
    /// The shape's width and height spring separately, like the iPhone's Dynamic Island: opening,
    /// it stretches sideways first and then drops down, overshooting a little; closing, it pulls
    /// up quickly and snaps in from the sides.
    static func widthAnimation(expanded: Bool) -> Animation {
        expanded ? .spring(duration: 0.5, bounce: 0.28) : .spring(duration: 0.45, bounce: 0.22)
    }
    static func heightAnimation(expanded: Bool) -> Animation {
        expanded ? .spring(duration: 0.6, bounce: 0.22) : .spring(duration: 0.36, bounce: 0)
    }
    /// The swell while the cursor rests on the collapsed notch.
    static let hoverAnimation = Animation.spring(duration: 0.3, bounce: 0.45)

    @Published var isExpanded = false
    /// The cursor rests on the collapsed notch and it's about to open: it swells a little.
    @Published var isHoverPrimed = false
    /// Music is playing: artwork and equalizer on the collapsed notch.
    @Published var hasLiveActivity = false
    /// Shown for a moment after the charger is connected or the battery runs low; on the open
    /// notch too, next to the camera.
    @Published var batteryFlash: BatteryEvent?
    /// Shown for a moment after picking a color from the screen.
    @Published var colorFlash: PickedColor?
    /// A voice memo is being recorded; shown until it stops.
    @Published var recordingSince: Date?
    /// An add-chat / add-link form is open: the notch stays expanded and takes keyboard input.
    @Published var isEditing = false
    /// Opened with the global shortcut: stays open without the mouse and takes keyboard input.
    @Published var isKeyboardOpened = false
    /// Item picked with the arrow keys in the current tab.
    @Published var keyboardSelection: Int?
    /// Spotify's volume, shown next to the camera for a moment after a scroll gesture.
    @Published var volumeFeedback: Int?
    @Published var selectedTab = NotchTab(rawValue: UserDefaults.standard.string(forKey: "selectedTab") ?? "") ?? .music {
        didSet {
            UserDefaults.standard.set(selectedTab.rawValue, forKey: "selectedTab")
            keyboardSelection = nil
        }
    }
    @Published private(set) var notchSize = CGSize(width: 185, height: 32)
    /// Chosen in Settings; the battery tab is there only while the batt tool is installed.
    @Published private(set) var tabs = TabSettings.shared.visibleTabs(battAvailable: BattController.isInstalled)
    private var isBattAvailable = BattController.isInstalled

    /// Width of the concave "ears" that blend the shape into the top edge of the screen.
    let collapsedEar: CGFloat = 6
    let expandedEar: CGFloat = 14

    var ear: CGFloat { isExpanded ? expandedEar : collapsedEar }

    var collapsedActivity: CollapsedActivity? {
        if let recordingSince { return .recording(since: recordingSince) }
        if let colorFlash { return .pickedColor(colorFlash) }
        if let batteryFlash { return .battery(batteryFlash) }
        return hasLiveActivity ? .music : nil
    }

    /// Extra width on each side of the collapsed notch while it shows an activity.
    /// A picked color needs room for its hex code.
    var activitySideWidth: CGFloat {
        colorFlash != nil && recordingSince == nil ? 76 : notchSize.height + 8
    }

    /// The meeting form with a date row: four 30pt rows and the buttons, with spacing.
    private static let minimumContentHeight: CGFloat = 190

    var expandedSize: CGSize {
        // Tall enough for the navigation rail (see `NavigationRail.height`) and the tallest form,
        // plus the paddings around them.
        let content = max(NavigationRail.height(tabCount: tabs.count), Self.minimumContentHeight)
        return CGSize(width: 720, height: notchSize.height + content + 20)
    }

    /// Window is fixed at the largest size plus room for the shadow; the shape animates inside it.
    var windowSize: CGSize {
        CGSize(width: expandedSize.width + 60, height: expandedSize.height + 40)
    }

    var currentSize: CGSize {
        if isExpanded { return expandedSize }
        let sides = collapsedActivity != nil ? activitySideWidth * 2 : 0
        let swell: CGSize = isHoverPrimed ? CGSize(width: 12, height: 4) : .zero
        return CGSize(
            width: notchSize.width + collapsedEar * 2 + sides + swell.width,
            height: notchSize.height + swell.height
        )
    }

    init() {
        // The last used tab may have been hidden since.
        if !tabs.contains(selectedTab), let first = tabs.first { selectedTab = first }
    }

    func setBatteryTabAvailable(_ available: Bool) {
        isBattAvailable = available
        updateTabs()
    }

    /// Call after the tab settings change.
    func updateTabs() {
        let newTabs = TabSettings.shared.visibleTabs(battAvailable: isBattAvailable)
        guard newTabs != tabs else { return }
        tabs = newTabs
        if !tabs.contains(selectedTab), let first = tabs.first { selectedTab = first }
    }

    func update(for screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - left.width - right.width, height: top)
        } else {
            // No notch: fake a small island at the top of the menu bar.
            notchSize = CGSize(width: 180, height: NSStatusBar.system.thickness)
        }
    }

    /// The strip level with the camera across the open notch: scroll gestures work there, whatever
    /// tab is open (the tab's content starts below it). Extends above the screen edge like `hitRect`.
    func gestureRect(in screen: NSScreen) -> CGRect {
        let size = currentSize
        return CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - notchSize.height,
            width: size.width,
            height: notchSize.height + 10
        )
    }

    /// Hover area in screen coordinates. Extends a bit above the screen edge so the very top pixel counts.
    func hitRect(in screen: NSScreen) -> CGRect {
        let size = currentSize
        return CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height + 10
        )
    }
}
