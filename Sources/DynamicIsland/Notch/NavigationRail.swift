import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case music, shelf, chats, links, meetings, clipboard, notes, battery

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .music: "music.note"
        case .shelf: "tray.full.fill"
        case .chats: "bubble.left.and.bubble.right.fill"
        case .links: "link"
        case .meetings: "video.fill"
        case .clipboard: "doc.on.clipboard.fill"
        case .notes: "note.text"
        case .battery: "battery.75percent"
        }
    }

    var title: String {
        switch self {
        case .music: L("Музыка", "Music")
        case .shelf: L("Полка", "Shelf")
        case .chats: L("Чаты", "Chats")
        case .links: L("Ссылки", "Links")
        case .meetings: L("Созвоны", "Meetings")
        case .clipboard: L("Буфер обмена", "Clipboard")
        case .notes: L("Заметки", "Notes")
        case .battery: L("Батарея (batt)", "Battery (batt)")
        }
    }
}

/// Tabs on the left of the expanded notch. Settings live in the top-right corner instead:
/// the tabs plus a gear don't fit the height.
struct NavigationRail: View {
    @Binding var selection: NotchTab
    let tabs: [NotchTab]

    /// How far the lens is stretched while it travels; 0 at rest.
    @State private var stretch: CGFloat = 0

    /// The smallest a tab gets; the expanded notch is never shorter than that.
    private static let minItemHeight: CGFloat = 24
    private static let spacing: CGFloat = 3
    static let width: CGFloat = 40

    /// The expanded notch is sized to fit at least this.
    static func height(tabCount: Int) -> CGFloat {
        let count = CGFloat(tabCount)
        return count * minItemHeight + (count - 1) * spacing
    }

    var body: some View {
        // The tabs share the whole height, top to bottom, whatever their number and the notch's size;
        // the icons grow with them.
        GeometryReader { proxy in
            let count = CGFloat(max(tabs.count, 1))
            let itemHeight = max((proxy.size.height - (count - 1) * Self.spacing) / count, Self.minItemHeight)
            let iconSize = min(max(itemHeight * 0.52, 13), 20)
            let index = CGFloat(tabs.firstIndex(of: selection) ?? 0)
            let shape = RoundedRectangle(cornerRadius: itemHeight * 0.36, style: .continuous)

            VStack(spacing: Self.spacing) {
                ForEach(tabs) { tab in
                    IconButton(
                        icon: tab.icon,
                        title: tab.title,
                        isSelected: selection == tab,
                        width: Self.width,
                        height: itemHeight,
                        iconSize: iconSize
                    ) {
                        select(tab)
                    }
                }
            }
            // One glass lens under the icons that travels to the selected tab, like the iOS 26 tab bar:
            // it slides on a spring, stretching tall and thin on the way and wobbling back into shape.
            .background(alignment: .top) {
                Color.clear
                    .frame(width: Self.width, height: itemHeight)
                    .notchGlass(in: shape, fallback: .white.opacity(0.14))
                    .scaleEffect(x: 1 - stretch * 0.25, y: 1 + stretch, anchor: .center)
                    .offset(y: index * (itemHeight + Self.spacing))
                    .animation(.spring(duration: 0.5, bounce: 0.3), value: index)
            }
        }
        .frame(width: Self.width)
    }

    private func select(_ tab: NotchTab) {
        guard tab != selection else { return }
        let from = tabs.firstIndex(of: selection) ?? 0
        let to = tabs.firstIndex(of: tab) ?? 0
        // A longer jump stretches the lens more.
        let amount = min(0.25 + 0.15 * CGFloat(abs(to - from)), 0.7)

        withAnimation(.easeOut(duration: 0.12)) { stretch = amount }
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) { selection = tab }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            withAnimation(.spring(duration: 0.45, bounce: 0.55)) { stretch = 0 }
        }
    }
}

/// An icon that brightens on hover and when selected: a tab, or the settings gear.
struct IconButton: View {
    let icon: String
    let title: String
    /// Only brightens the icon: a tab's selection glass is drawn by `NavigationRail`.
    let isSelected: Bool
    var width: CGFloat = NavigationRail.width
    var height: CGFloat = 28
    var iconSize: CGFloat = 14
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 1 : isHovering ? 0.75 : 0.45))
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: min(height * 0.36, 10), style: .continuous)
                        .fill(.white.opacity(isHovering && !isSelected ? 0.07 : 0))
                )
                .contentShape(Rectangle())
                .animation(.easeOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(title)
    }
}
