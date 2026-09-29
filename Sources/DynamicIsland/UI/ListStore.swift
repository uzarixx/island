import Foundation

/// A list the user builds up in the notch (chats, links): kept in the user's order and saved to
/// UserDefaults as JSON on every change.
@MainActor
class ListStore<Item: Codable & Identifiable & Equatable>: ObservableObject where Item.ID == UUID {
    @Published var items: [Item] {
        didSet { save() }
    }

    private let defaultsKey: String

    init(defaultsKey: String) {
        self.defaultsKey = defaultsKey
        let data = UserDefaults.standard.data(forKey: defaultsKey)
        items = data.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
    }

    func add(_ item: Item) {
        items.append(item)
    }

    /// Replaces the item with the same id, keeping its place.
    func update(_ item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
    }

    /// Puts the item `id` where `targetID` is (drag and drop in the notch).
    func move(_ id: UUID, to targetID: UUID) {
        guard let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == targetID }) else { return }
        items.insert(items.remove(at: from), at: to)
    }

    /// One step up or down (the arrows in Settings).
    func move(_ item: Item, by offset: Int) {
        guard let index = items.firstIndex(of: item) else { return }
        let target = index + offset
        guard items.indices.contains(target) else { return }
        items.swapAt(index, target)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
