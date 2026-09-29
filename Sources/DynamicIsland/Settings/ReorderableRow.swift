import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Lets the row be dragged to a new place among its siblings; the rows rearrange live under
    /// the cursor, like the tiles in the notch.
    func reorderable<ID: Hashable>(_ id: ID, dragged: Binding<ID?>, move: @escaping (_ id: ID, _ target: ID) -> Void) -> some View {
        modifier(ReorderableRow(id: id, dragged: dragged, move: move))
    }
}

/// The handle at the end of a reorderable row, as in System Settings.
struct DragHandle: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.tertiary)
            .help(L("Перетащи, чтобы поменять порядок", "Drag to reorder"))
    }
}

private struct ReorderableRow<ID: Hashable>: ViewModifier {
    let id: ID
    @Binding var dragged: ID?
    let move: (ID, ID) -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .opacity(dragged == id ? 0.35 : 1)
            .onDrag {
                dragged = id
                // SwiftUI doesn't report a drag that ends outside a drop target; clear the state
                // once the mouse button is released.
                Task { @MainActor in
                    while NSEvent.pressedMouseButtons & 1 != 0 {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    dragged = nil
                }
                // The rows know what's dragged from `dragged`; the payload only marks it as ours.
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.tile.identifier, visibility: .ownProcess) { completion in
                    completion(Data(), nil)
                    return nil
                }
                return provider
            }
            .onDrop(of: [.tile], delegate: RowDropDelegate(id: id, dragged: $dragged, move: move))
    }
}

private struct RowDropDelegate<ID: Hashable>: DropDelegate {
    let id: ID
    @Binding var dragged: ID?
    let move: (ID, ID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil && info.hasItemsConforming(to: [.tile])
    }

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != id else { return }
        withAnimation(.spring(duration: 0.25)) { move(dragged, id) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}
