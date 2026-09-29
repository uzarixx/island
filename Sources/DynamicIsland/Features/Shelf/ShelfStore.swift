import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct ShelfItem: Identifiable, Codable, Equatable {
    enum Content: Codable, Equatable {
        /// A file or folder, remembered by a bookmark so it's found again after it's renamed or
        /// moved. `isOwned` files were made by the shelf (a dropped picture, a ZIP) and live in
        /// its own folder; they're deleted with the item.
        case file(bookmark: Data, path: String, isOwned: Bool)
        case link(URL)
        case text(String)
    }

    var id = UUID()
    var content: Content
    var added = Date()
}

/// Files, links and snippets dropped on the notch, kept until they're dragged somewhere else.
/// Files aren't copied: the shelf only points at them. It's saved across launches.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = [] {
        didSet { save() }
    }
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    /// A ZIP of the whole shelf is being made.
    @Published private(set) var isArchiving = false
    /// Briefly set when something lands on the shelf, for the arrival animation.
    @Published private(set) var lastAddedIDs: Set<UUID> = []

    /// Current locations of file items; bookmarks are resolved once per launch and on refresh.
    private var locations: [UUID: URL] = [:]
    private var addedResetTask: Task<Void, Never>?

    private static let defaultsKey = "shelfItems"
    /// Where pictures dropped as data and archives made by the shelf are kept.
    nonisolated static let directory = AppSettings.dataDirectory.appending(path: "Shelf")
    private static let thumbnailSize = CGSize(width: 112, height: 72)

    init() {
        let data = UserDefaults.standard.data(forKey: Self.defaultsKey)
        items = data.flatMap { try? JSONDecoder().decode([ShelfItem].self, from: $0) } ?? []
        refresh()
    }

    // MARK: - Reading

    func url(of item: ShelfItem) -> URL? {
        switch item.content {
        case .file: locations[item.id]
        case .link(let url): url
        case .text: nil
        }
    }

    var fileURLs: [URL] {
        items.compactMap { item in
            guard case .file = item.content else { return nil }
            return locations[item.id]
        }
    }

    /// "3 файла · 12,4 МБ"; "5 шт." when there are links or text too.
    var summary: String {
        let files = fileURLs
        let size = files.reduce(Int64(0)) { $0 + Self.size(of: $1) }
        var parts = [files.count == items.count ? Self.countDescription(items.count) : plural(items.count, "шт.", "шт.", "шт.", "item", "items")]
        if size > 0 { parts.append(Self.formatSize(size)) }
        return parts.joined(separator: " · ")
    }

    /// Looks for moved files again and drops the ones that are gone or in the Trash.
    func refresh() {
        var stale: [(Int, Data)] = []
        var missing: Set<UUID> = []
        for (index, item) in items.enumerated() {
            guard case .file(let bookmark, let path, _) = item.content else { continue }
            var isStale = false
            let url = (try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &isStale))
                ?? URL(filePath: path)
            guard FileManager.default.fileExists(atPath: url.path), !url.path.contains("/.Trash/") else {
                missing.insert(item.id)
                continue
            }
            locations[item.id] = url
            if isStale, let fresh = try? url.bookmarkData() { stale.append((index, fresh)) }
        }
        for (index, bookmark) in stale {
            if case .file(_, _, let isOwned) = items[index].content, let url = locations[items[index].id] {
                items[index].content = .file(bookmark: bookmark, path: url.path, isOwned: isOwned)
            }
        }
        if !missing.isEmpty {
            items.removeAll { missing.contains($0.id) }
            missing.forEach { locations[$0] = nil; thumbnails[$0] = nil }
        }
        items.forEach(loadThumbnail)
    }

    // MARK: - Adding

    /// Takes whatever was dropped: files, pictures, web links or text.
    func add(from providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                    guard let url = url as? URL, url.isFileURL else { return }
                    Task { @MainActor in self.addFile(url) }
                }
            } else if let imageType = provider.registeredTypeIdentifiers.compactMap(UTType.init).first(where: { $0.conforms(to: .image) }) {
                accepted = true
                let name = provider.suggestedName
                provider.loadDataRepresentation(forTypeIdentifier: imageType.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in self.addImage(data, type: imageType, name: name) }
                }
            } else if provider.canLoadObject(ofClass: NSURL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSURL.self) { url, _ in
                    guard let url = url as? URL else { return }
                    Task { @MainActor in
                        url.isFileURL ? self.addFile(url) : self.insert(ShelfItem(content: .link(url)))
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                    guard let text = (string as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
                    Task { @MainActor in self.insert(ShelfItem(content: .text(text))) }
                }
            }
        }
        return accepted
    }

    /// Takes what's on the clipboard: files copied in Finder, a screenshot (⌃⇧⌘4) or a copied
    /// picture, a link or text. Returns false when there's nothing to take.
    @discardableResult
    func paste(from pasteboard: NSPasteboard = .general) -> Bool {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty {
            files.forEach { addFile($0) }
            return true
        }
        // Screenshots come as PNG; pictures copied from apps often only as TIFF.
        if let png = pasteboard.data(forType: .png) {
            addImage(png, type: .png, name: Self.pastedImageName())
            return true
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            addImage(png, type: .png, name: Self.pastedImageName())
            return true
        }
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first, url.scheme?.hasPrefix("http") == true {
            insert(ShelfItem(content: .link(url)))
            return true
        }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if let url = URL(string: text), url.scheme?.hasPrefix("http") == true, url.host != nil, !text.contains(" ") {
                insert(ShelfItem(content: .link(url)))
            } else {
                insert(ShelfItem(content: .text(text)))
            }
            return true
        }
        return false
    }

    /// "Снимок экрана 2026-09-30 в 12.34.56", like the screenshots macOS saves.
    private static func pastedImageName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        formatter.dateFormat = "HH.mm.ss"
        let time = formatter.string(from: Date())
        // With the extension: `addImage` drops it, and would take ".56" for one.
        return L("Снимок экрана \(day) в \(time).png", "Screenshot \(day) at \(time).png")
    }

    func addFile(_ url: URL, isOwned: Bool = false) {
        // The same file again just comes to the front.
        if let existing = items.first(where: { locations[$0.id]?.standardizedFileURL == url.standardizedFileURL }) {
            moveToFront(existing.id)
            return
        }
        guard let bookmark = try? url.bookmarkData() else { return }
        let item = ShelfItem(content: .file(bookmark: bookmark, path: url.path, isOwned: isOwned))
        locations[item.id] = url
        insert(item)
    }

    /// A picture dragged from a browser or an app comes as data: it's saved as a file.
    private func addImage(_ data: Data, type: UTType, name: String?) {
        let fileExtension = type.preferredFilenameExtension ?? "png"
        let base = name.map { ($0 as NSString).deletingPathExtension }.flatMap { $0.isEmpty ? nil : $0 } ?? L("Изображение", "Image")
        guard let url = Self.ownedFileURL(named: "\(base).\(fileExtension)"), (try? data.write(to: url)) != nil else { return }
        addFile(url, isOwned: true)
    }

    private func insert(_ item: ShelfItem) {
        // The same link or text again just comes to the front.
        if let existing = items.first(where: { $0.content == item.content }) {
            moveToFront(existing.id)
            return
        }
        // Dropped things load in the background, after the drop's own animation: animate here.
        withAnimation(.spring(duration: 0.45, bounce: 0.3)) { items.insert(item, at: 0) }
        loadThumbnail(item)
        lastAddedIDs.insert(item.id)
        addedResetTask?.cancel()
        addedResetTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            lastAddedIDs = []
        }
    }

    private func moveToFront(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index > 0 else { return }
        withAnimation(.spring(duration: 0.35)) { items.insert(items.remove(at: index), at: 0) }
    }

    // MARK: - Removing

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        forget(item)
    }

    func clear() {
        let removed = items
        items.removeAll()
        removed.forEach(forget)
    }

    private func forget(_ item: ShelfItem) {
        if case .file(_, _, true) = item.content, let url = locations[item.id],
           url.path.hasPrefix(Self.directory.path) {
            // Each owned file has a folder of its own.
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        locations[item.id] = nil
        thumbnails[item.id] = nil
    }

    // MARK: - Actions

    /// Opens a file with its app, a link in the browser.
    func open(_ item: ShelfItem) {
        if let url = url(of: item) { NSWorkspace.shared.open(url) }
    }

    func revealInFinder(_ item: ShelfItem) {
        if let url = locations[item.id] { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func quickLook(_ item: ShelfItem) {
        let files = items.compactMap { locations[$0.id] }
        guard let url = locations[item.id], let index = files.firstIndex(of: url) else {
            open(item)
            return
        }
        ShelfQuickLook.shared.show(files, at: index)
    }

    /// What goes to another app for `items`: files, links and text as they are.
    func pasteboardObjects(for items: [ShelfItem]) -> [NSPasteboardWriting] {
        items.compactMap { item in
            switch item.content {
            case .file: locations[item.id] as NSURL?
            case .link(let url): url as NSURL
            case .text(let text): text as NSString
            }
        }
    }

    func dragProvider(for item: ShelfItem) -> NSItemProvider {
        switch item.content {
        case .file:
            guard let url = locations[item.id] else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
        case .link(let url):
            return NSItemProvider(object: url as NSURL)
        case .text(let text):
            return NSItemProvider(object: text as NSString)
        }
    }

    /// Opens the AirDrop sheet for `items` (the whole shelf by default).
    func airDrop(_ items: [ShelfItem]? = nil) {
        let objects = pasteboardObjects(for: items ?? self.items)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: objects) else { return }
        // The sheet only takes the keyboard from an active app.
        NSApp.activate()
        service.perform(withItems: objects)
    }

    /// Packs every file on the shelf into one ZIP, which lands on the shelf too.
    func archiveAll() {
        let files = fileURLs
        guard !files.isEmpty, !isArchiving else { return }
        isArchiving = true
        let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : L("Архив", "Archive")
        Task {
            let archive = await Self.makeArchive(of: files, named: name)
            isArchiving = false
            if let archive { addFile(archive, isOwned: true) }
        }
    }

    // MARK: - Private

    private func loadThumbnail(_ item: ShelfItem) {
        guard thumbnails[item.id] == nil, let url = locations[item.id] else { return }
        // The file's icon right away; the real preview replaces it when it's ready.
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: url.path)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: Self.thumbnailSize,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor in
                guard self.locations[id] != nil else { return }
                self.thumbnails[id] = image
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// A new file in a folder of its own inside the shelf's directory, so names never clash.
    private static func ownedFileURL(named name: String) -> URL? {
        let folder = directory.appending(path: UUID().uuidString)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        return folder.appending(path: name)
    }

    /// Copies are clones on APFS (instant, no extra space); ditto packs them like Finder's "Сжать".
    private nonisolated static func makeArchive(of files: [URL], named name: String) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let fileManager = FileManager.default
            let folder = directory.appending(path: UUID().uuidString)
            let staging = fileManager.temporaryDirectory.appending(path: "DynamicIsland-Shelf-\(UUID().uuidString)")
            let content = staging.appending(path: name)
            defer { try? fileManager.removeItem(at: staging) }
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let source: URL
                if files.count == 1 {
                    source = files[0]
                } else {
                    try fileManager.createDirectory(at: content, withIntermediateDirectories: true)
                    var used: Set<String> = []
                    for file in files {
                        var target = file.lastPathComponent
                        var copy = 2
                        while used.contains(target) {
                            target = "\(file.deletingPathExtension().lastPathComponent) \(copy).\(file.pathExtension)"
                            copy += 1
                        }
                        used.insert(target)
                        try fileManager.copyItem(at: file, to: content.appending(path: target))
                    }
                    source = content
                }
                let archive = folder.appending(path: "\(name).zip")
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/ditto")
                process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    try? fileManager.removeItem(at: folder)
                    return nil
                }
                return archive
            } catch {
                try? fileManager.removeItem(at: folder)
                return nil
            }
        }.value
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
        if values?.isDirectory == true { return 0 }
        return Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
    }

    static func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// "1 файл", "3 файла", "5 файлов".
    static func countDescription(_ count: Int) -> String {
        plural(count, "файл", "файла", "файлов", "file", "files")
    }
}
