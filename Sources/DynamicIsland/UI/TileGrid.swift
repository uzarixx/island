import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Our own drag type for reordering tiles, declared in Info.plist. Using it instead of plain
    /// text keeps a reorder from looking like a link dropped from the browser, and vice versa.
    static let tile = UTType(exportedAs: "com.andrei.dynamicisland.tile")
}

/// Grid of icon + title tiles: click opens, drag reorders, right click shows a popover
/// with "Изменить" / "Удалить". Used by the chats and links tabs.
struct TileGrid<Item: Identifiable, Icon: View>: View where Item.ID == UUID {
    let items: [Item]
    let title: (Item) -> String
    let help: (Item) -> String
    let open: (Item) -> Void
    let edit: (Item) -> Void
    let delete: (Item) -> Void
    /// Moves the first item to the second one's place.
    let move: (UUID, UUID) -> Void
    /// Shows a "+" tile at the end of the grid.
    let add: () -> Void
    /// Tile picked with the arrow keys.
    var selectedID: UUID? = nil
    @ViewBuilder let icon: (Item) -> Icon

    static var iconSize: CGFloat { 46 }

    /// Item whose right-click popover is shown.
    @State private var menuItemID: UUID?
    /// Item being dragged to a new place.
    @State private var draggedID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 10) {
                    ForEach(items) { item in
                        Tile(
                            title: title(item),
                            help: help(item),
                            isSelected: selectedID == item.id,
                            open: { open(item) },
                            showMenu: { menuItemID = item.id }
                        ) {
                            icon(item)
                        }
                        .id(item.id)
                        .opacity(draggedID == item.id ? 0.35 : 1)
                        .anchorPreference(key: TileBoundsKey.self, value: .bounds) { [item.id: $0] }
                        .onDrag {
                            menuItemID = nil
                            draggedID = item.id
                            // SwiftUI doesn't report a drag that ends outside a drop target;
                            // clear the state once the mouse button is released.
                            Task { @MainActor in
                                while NSEvent.pressedMouseButtons & 1 != 0 {
                                    try? await Task.sleep(for: .milliseconds(100))
                                }
                                draggedID = nil
                            }
                            let provider = NSItemProvider()
                            provider.registerDataRepresentation(forTypeIdentifier: UTType.tile.identifier, visibility: .ownProcess) { completion in
                                completion(Data(item.id.uuidString.utf8), nil)
                                return nil
                            }
                            return provider
                        }
                        .onDrop(of: [.tile], delegate: ReorderDropDelegate(targetID: item.id, draggedID: $draggedID, move: move))
                    }
                    Tile(title: L("Добавить", "Add"), help: L("Добавить (N)", "Add (N)"), isSelected: false, open: add, showMenu: {}) {
                        Circle()
                            .strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .frame(width: Self.iconSize, height: Self.iconSize)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                            )
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedID) {
                guard let selectedID else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(selectedID) }
            }
        }
        // Drawn inside the notch rather than as an NSPopover: a separate popover window
        // sits outside the hover area, so the notch would collapse and close it.
        .overlayPreferenceValue(TileBoundsKey.self) { tiles in
            GeometryReader { proxy in
                if let id = menuItemID, let anchor = tiles[id], let item = items.first(where: { $0.id == id }) {
                    menuLayer(for: item, tile: proxy[anchor], in: proxy.size)
                }
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: menuItemID)
    }

    private func menuLayer(for item: Item, tile: CGRect, in size: CGSize) -> some View {
        // Next to the icon (top of the tile): on its right, or on its left if there's no room.
        let iconCenter = CGPoint(x: tile.midX, y: tile.minY + Self.iconSize / 2)
        let offset = Self.iconSize / 2 + 4 + TileMenu.totalWidth / 2
        let fitsOnRight = iconCenter.x + offset + TileMenu.totalWidth / 2 <= size.width
        let x = fitsOnRight ? iconCenter.x + offset : iconCenter.x - offset
        let y = min(max(iconCenter.y, TileMenu.height / 2), size.height - TileMenu.height / 2)

        return ZStack {
            // Any click outside the menu, left or right, closes it.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { menuItemID = nil }
                .overlay(RightClickCatcher { menuItemID = nil })

            TileMenu(
                arrowEdge: fitsOnRight ? .leading : .trailing,
                edit: {
                    menuItemID = nil
                    edit(item)
                },
                delete: {
                    menuItemID = nil
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        delete(item)
                    }
                }
            )
            .position(x: x, y: y)
            .transition(.scale(scale: 0.85, anchor: fitsOnRight ? .leading : .trailing).combined(with: .opacity))
        }
    }
}

/// Moves the dragged tile into a tile's place as soon as the drag enters it, so the grid
/// rearranges live under the cursor.
private struct ReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let move: (UUID, UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.tile])
    }

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        withAnimation(.spring(duration: 0.25)) { move(draggedID, targetID) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }
}

private struct TileBoundsKey: PreferenceKey {
    static var defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct Tile<Icon: View>: View {
    let title: String
    let help: String
    let isSelected: Bool
    let open: () -> Void
    let showMenu: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 5) {
                icon()
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovering || isSelected ? 1 : 0.8))
                    .lineLimit(1)
            }
            .frame(width: 76)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.14 : 0))
            )
            .scaleEffect(isHovering || isSelected ? 1.06 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovering || isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .overlay(RightClickCatcher(action: showMenu))
    }
}

/// Popover-style bubble with an arrow pointing at the icon.
private struct TileMenu: View {
    /// Fixed so the menu can be positioned next to the icon: two 24pt rows plus spacing and padding.
    static let width: CGFloat = 110
    static let height: CGFloat = 58
    static let arrowSize: CGFloat = 6

    /// Bubble plus arrow.
    static var totalWidth: CGFloat { width + arrowSize }

    /// Side the arrow is on, i.e. the side facing the icon.
    let arrowEdge: HorizontalEdge
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            MenuButton(title: L("Изменить", "Edit"), systemImage: "pencil", tint: .white, action: edit)
            MenuButton(title: L("Удалить", "Delete"), systemImage: "trash", tint: .red, action: delete)
        }
        .padding(4)
        .frame(width: Self.width, height: Self.height)
        // Leave room for the arrow on its side; bubble and arrow are one shape so the glass is one piece.
        .padding(arrowEdge == .leading ? .leading : .trailing, Self.arrowSize)
        .notchGlass(
            in: BubbleShape(arrowEdge: arrowEdge, arrowSize: Self.arrowSize, cornerRadius: 10),
            fallback: Color(white: 0.16)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
    }
}

/// A rounded rectangle with a small arrow on one side, pointing out of the view's bounds' edge.
private struct BubbleShape: Shape {
    let arrowEdge: HorizontalEdge
    let arrowSize: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = arrowEdge == .leading
            ? CGRect(x: rect.minX + arrowSize, y: rect.minY, width: rect.width - arrowSize, height: rect.height)
            : CGRect(x: rect.minX, y: rect.minY, width: rect.width - arrowSize, height: rect.height)
        var path = Path(roundedRect: body, cornerRadius: cornerRadius, style: .continuous)
        let arrow = arrowEdge == .leading
            ? CGRect(x: rect.minX, y: rect.midY - arrowSize, width: arrowSize + 1, height: arrowSize * 2)
            : CGRect(x: body.maxX - 1, y: rect.midY - arrowSize, width: arrowSize + 1, height: arrowSize * 2)
        path.addPath(Arrow(pointsTo: arrowEdge).path(in: arrow))
        return path
    }
}

private struct Arrow: Shape {
    let pointsTo: HorizontalEdge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tipX = pointsTo == .leading ? rect.minX : rect.maxX
        let baseX = pointsTo == .leading ? rect.maxX : rect.minX
        path.move(to: CGPoint(x: baseX, y: rect.minY))
        path.addLine(to: CGPoint(x: tipX, y: rect.midY))
        path.addLine(to: CGPoint(x: baseX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct MenuButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(isHovering ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Transparent overlay that reacts to right clicks only; left clicks and hover pass through.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .rightMouseDown || event.type == .rightMouseUp else {
                return nil
            }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
