import AppKit
import Quartz
import SwiftUI

/// The Quick Look panel for files on the shelf; ← → in it go through the whole shelf.
@MainActor
final class ShelfQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = ShelfQuickLook()

    private var urls: [URL] = []

    func show(_ urls: [URL], at index: Int) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        // The panel takes the keyboard only from an active app.
        NSApp.activate()
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] as NSURL : nil }
    }
}

/// Drags several things out at once, as a fanned stack (SwiftUI's `onDrag` carries one item).
/// A click without a drag calls `click`.
struct MultiDragSource<Label: View>: NSViewRepresentable {
    let objects: () -> [NSPasteboardWriting]
    let images: () -> [NSImage]
    var click: () -> Void = {}
    /// Called once the things were dropped somewhere.
    var dropped: () -> Void = {}
    @ViewBuilder let label: () -> Label

    func makeNSView(context: Context) -> SourceView {
        let view = SourceView(frame: .zero)
        let hosting = NSHostingView(rootView: AnyView(label()))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.hosting = hosting
        update(view)
        return view
    }

    func updateNSView(_ view: SourceView, context: Context) {
        view.hosting?.rootView = AnyView(label())
        update(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SourceView, context: Context) -> CGSize? {
        nsView.hosting?.fittingSize
    }

    private func update(_ view: SourceView) {
        view.objects = objects
        view.images = images
        view.click = click
        view.dropped = dropped
    }

    final class SourceView: NSView, NSDraggingSource {
        var hosting: NSHostingView<AnyView>?
        var objects: () -> [NSPasteboardWriting] = { [] }
        var images: () -> [NSImage] = { [] }
        var click: () -> Void = {}
        var dropped: () -> Void = {}
        private var mouseDownEvent: NSEvent?

        /// The label is for looks: the mouse is handled here.
        override func hitTest(_ point: NSPoint) -> NSView? {
            frame.contains(point) ? self : nil
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownEvent else { return }
            let distance = hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y)
            guard distance > 3 else { return }
            mouseDownEvent = nil

            let objects = objects()
            guard !objects.isEmpty else { return }
            let images = images()
            let origin = convert(event.locationInWindow, from: nil)
            let items = objects.enumerated().map { index, object in
                let item = NSDraggingItem(pasteboardWriter: object)
                // The first few fan out behind the cursor; the rest sit under the top one.
                let image = images.indices.contains(index) ? images[index] : NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
                let step = CGFloat(min(index, 3)) * 6
                item.setDraggingFrame(NSRect(x: origin.x - 24 + step, y: origin.y - 24 - step, width: 48, height: 48), contents: image)
                return item
            }
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.draggingFormation = .stack
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        override func mouseUp(with event: NSEvent) {
            if mouseDownEvent != nil { click() }
            mouseDownEvent = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .link, .generic] : []
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            if operation != [] { dropped() }
        }
    }
}
