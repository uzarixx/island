import Foundation

/// Which tabs the notch shows and in what order, set in Settings.
@MainActor
final class TabSettings: ObservableObject {
    static let shared = TabSettings()

    /// Every tab, in the user's order.
    @Published private(set) var order: [NotchTab]
    @Published private(set) var hidden: Set<NotchTab>

    private static let orderKey = "tabOrder"
    private static let hiddenKey = "hiddenTabs"

    private init() {
        let stored = (UserDefaults.standard.stringArray(forKey: Self.orderKey) ?? []).compactMap(NotchTab.init(rawValue:))
        var order = stored.filter { NotchTab.allCases.contains($0) }
        // Tabs added in a newer version go where they are by default, not to the end.
        for (index, tab) in NotchTab.allCases.enumerated() where !order.contains(tab) {
            order.insert(tab, at: min(index, order.count))
        }
        self.order = order
        hidden = Set((UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []).compactMap(NotchTab.init(rawValue:)))
    }

    /// The visible tabs in order; the battery tab only while batt is installed.
    func visibleTabs(battAvailable: Bool) -> [NotchTab] {
        let tabs = order.filter { !hidden.contains($0) && ($0 != .battery || battAvailable) }
        // Hiding everything would leave an empty notch.
        return tabs.isEmpty ? [order.first ?? .music] : tabs
    }

    func isVisible(_ tab: NotchTab) -> Bool {
        !hidden.contains(tab)
    }

    /// The last visible tab can't be hidden.
    func canHide(_ tab: NotchTab) -> Bool {
        order.filter { !hidden.contains($0) && $0 != tab }.count > 0
    }

    func setVisible(_ tab: NotchTab, _ visible: Bool) {
        if visible {
            hidden.remove(tab)
        } else if canHide(tab) {
            hidden.insert(tab)
        }
        UserDefaults.standard.set(hidden.map(\.rawValue).sorted(), forKey: Self.hiddenKey)
    }

    /// Puts `tab` where `target` is (drag and drop in Settings).
    func move(_ tab: NotchTab, to target: NotchTab) {
        guard tab != target, let from = order.firstIndex(of: tab), let to = order.firstIndex(of: target) else { return }
        order.insert(order.remove(at: from), at: to)
        save()
    }

    func resetToDefault() {
        order = NotchTab.allCases
        hidden = []
        save()
        UserDefaults.standard.removeObject(forKey: Self.hiddenKey)
    }

    var isDefault: Bool {
        order == NotchTab.allCases && hidden.isEmpty
    }

    private func save() {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: Self.orderKey)
    }
}
