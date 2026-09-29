import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    /// Index picked with the arrow keys.
    var selection: Int? = nil

    @State private var isTargeted = false

    static let dropTypes: [UTType] = [.fileURL, .image, .url, .plainText]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !store.items.isEmpty {
                header
            }
            if store.items.isEmpty {
                ShelfDropZone(isTargeted: isTargeted, paste: paste)
            } else {
                cards
            }
        }
        .onDrop(of: Self.dropTypes, isTargeted: $isTargeted) { providers in
            store.add(from: providers)
        }
        .overlay {
            if isTargeted && !store.items.isEmpty {
                DropHighlight(text: L("Отпусти — добавлю к остальным", "Drop to add to the others"))
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: isTargeted)
        // Files may have been moved, renamed or deleted while the notch was closed.
        .onAppear(perform: store.refresh)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("Полка", "Shelf"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(store.summary)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .lineLimit(1)
            Spacer(minLength: 4)

            if store.items.count > 1 {
                MultiDragSource(
                    objects: { store.pasteboardObjects(for: store.items) },
                    images: { store.items.map { store.thumbnails[$0.id] ?? Self.icon(for: $0) } }
                ) {
                    StackHandle(images: store.items.prefix(3).map { store.thumbnails[$0.id] ?? Self.icon(for: $0) }, count: store.items.count)
                }
                .fixedSize()
                .help(L("Перетащи, чтобы забрать всё сразу", "Drag to take everything at once"))
            }
            HeaderButton(icon: "doc.on.clipboard", title: L("Вставить", "Paste"), help: L("Положить на полку то, что в буфере обмена: скриншот, картинку, файлы или текст (⌘V)", "Put what's on the clipboard on the shelf: a screenshot, a picture, files or text (⌘V)"), action: paste)
            HeaderButton(icon: "square.and.arrow.up", title: "AirDrop", help: L("Отправить всё по AirDrop", "Send all via AirDrop")) {
                store.airDrop()
            }
            if !store.fileURLs.isEmpty {
                HeaderButton(icon: "doc.zipper", title: "ZIP", help: L("Сжать все файлы в один архив", "Compress all files into one archive"), isBusy: store.isArchiving) {
                    withAnimation(.spring(duration: 0.4)) { store.archiveAll() }
                }
            }
            HeaderButton(icon: "xmark", title: L("Очистить", "Clear"), help: L("Убрать всё с полки (сами файлы останутся на месте)", "Remove everything from the shelf (the files stay where they are)")) {
                withAnimation(.spring(duration: 0.35)) { store.clear() }
            }
        }
        .padding(.horizontal, 2)
    }

    private var cards: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                        ShelfCard(
                            item: item,
                            store: store,
                            isSelected: selection == index,
                            isNew: store.lastAddedIDs.contains(item.id)
                        )
                        .id(item.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.4, anchor: .top).combined(with: .opacity).combined(with: .offset(y: -30)),
                            removal: .scale(scale: 0.6).combined(with: .opacity)
                        ))
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .onChange(of: selection) {
                guard let selection, store.items.indices.contains(selection) else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(store.items[selection].id, anchor: .center) }
            }
            .onChange(of: store.items.first?.id) {
                guard let first = store.items.first?.id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(first, anchor: .leading) }
            }
        }
    }

    private func paste() {
        if !store.paste() { NSSound.beep() }
    }

    static func symbol(for item: ShelfItem) -> String {
        switch item.content {
        case .file: "doc"
        case .link: "link"
        case .text: "text.alignleft"
        }
    }

    static func icon(for item: ShelfItem) -> NSImage {
        NSImage(systemSymbolName: symbol(for: item), accessibilityDescription: nil) ?? NSImage()
    }
}

// MARK: - Drop zone

/// The empty shelf: one big target that comes alive while something is dragged over it.
private struct ShelfDropZone: View {
    let isTargeted: Bool
    let paste: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isTargeted ? "tray.and.arrow.down.fill" : "tray")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(isTargeted ? Color.notchGreen : .white.opacity(0.5))
                .symbolEffect(.bounce, value: isTargeted)
                .contentTransition(.symbolEffect(.replace))
            Text(isTargeted ? L("Отпусти — подержу, пока не понадобится", "Drop — I’ll hold it until you need it") : L("Перетащи сюда файлы, картинки или ссылки", "Drag files, images or links here"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(isTargeted ? 0.95 : 0.8))
            Text(L("Потом утащишь их куда нужно: в другую папку, письмо или чат", "Then drag them wherever you need: another folder, an email or a chat"))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            if !isTargeted {
                HeaderButton(icon: "doc.on.clipboard", title: L("Вставить из буфера  ⌘V", "Paste from clipboard  ⌘V"), help: L("Скриншот, картинка, файлы или текст из буфера обмена", "A screenshot, a picture, files or text from the clipboard"), action: paste)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            MarchingBorder(isActive: isTargeted, cornerRadius: 16)
        }
        .scaleEffect(isTargeted ? 1.015 : 1)
        .animation(.spring(duration: 0.35, bounce: 0.4), value: isTargeted)
    }
}

/// Over a non-empty shelf while something is dragged onto it.
private struct DropHighlight: View {
    let text: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.72))
            MarchingBorder(isActive: true, cornerRadius: 14)
            Label(text, systemImage: "tray.and.arrow.down.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.notchGreen)
        }
        .allowsHitTesting(false)
    }
}

/// A dashed outline; while active it glows and its dashes run around it.
private struct MarchingBorder: View {
    let isActive: Bool
    let cornerRadius: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isActive)) { context in
            let phase = isActive ? CGFloat(context.date.timeIntervalSinceReferenceDate * 24).truncatingRemainder(dividingBy: 20) : 0
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape
                .fill(isActive ? Color.notchGreen.opacity(0.08) : .white.opacity(0.03))
                .overlay(
                    shape.strokeBorder(
                        isActive ? Color.notchGreen : .white.opacity(0.18),
                        style: StrokeStyle(lineWidth: isActive ? 2 : 1.5, dash: [7, 5], dashPhase: -phase)
                    )
                )
                .shadow(color: isActive ? Color.notchGreen.opacity(0.45) : .clear, radius: 10)
        }
    }
}

// MARK: - Header

/// Up to three thumbnails fanned like a stack, with the count: drag it to take everything.
private struct StackHandle: View {
    let images: [NSImage]
    let count: Int

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                ForEach(Array(images.enumerated().reversed()), id: \.offset) { index, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.black.opacity(0.4), lineWidth: 0.5))
                        .rotationEffect(.degrees(Double(index) * (isHovering ? 12 : 7)))
                        .offset(x: CGFloat(index) * (isHovering ? 4 : 2.5))
                }
            }
            .frame(width: 26, height: 18)
            Text(L("Все \(count)", "All \(count)"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(.white.opacity(isHovering ? 0.16 : 0.09)))
        .animation(.spring(duration: 0.3, bounce: 0.4), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct HeaderButton: View {
    let icon: String
    let title: String
    let help: String
    var isBusy = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.6))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(.white.opacity(isHovering ? 0.14 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Card

private struct ShelfCard: View {
    let item: ShelfItem
    @ObservedObject var store: ShelfStore
    let isSelected: Bool
    /// Just dropped: glows for a moment.
    let isNew: Bool

    @State private var isHovering = false
    @State private var copied = false

    private var url: URL? { store.url(of: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            preview
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .overlay(alignment: .bottom) {
                    if isHovering { actions.transition(.opacity.combined(with: .offset(y: 4))) }
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(copied ? L("Скопировано", "Copied") : subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(copied ? Color.notchGreen : .white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(width: 128, height: 116)
        .notchGlass(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            interactive: true,
            fallback: .white.opacity(isHovering ? 0.12 : 0.07)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isNew ? Color.notchGreen : .white.opacity(isSelected ? 0.6 : 0), lineWidth: 1.5)
        )
        .shadow(color: isNew ? Color.notchGreen.opacity(0.5) : .clear, radius: 8)
        .animation(.easeOut(duration: 0.4), value: isNew)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .overlay(alignment: .topTrailing) {
            if isHovering {
                Button {
                    withAnimation(.spring(duration: 0.3)) { store.remove(item) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.3))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help(L("Убрать с полки (файл останется на месте)", "Remove from shelf (the file stays where it is)"))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: primaryAction)
        .onDrag { store.dragProvider(for: item) } preview: {
            if case .file = item.content {
                DragPreview(image: store.thumbnails[item.id], title: title)
            } else {
                DragPreview(symbol: ShelfView.symbol(for: item), title: title)
            }
        }
        .onHover { isHovering = $0 }
        .help(help)
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .file:
            if let image = store.thumbnails[item.id] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.5))
            }
        case .link(let url):
            VStack(alignment: .leading, spacing: 3) {
                Image(systemName: "link")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.notchGreen)
                Text(url.path == "/" || url.path.isEmpty ? url.absoluteString : url.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .text(let text):
            Text(text.prefix(200))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if case .file = item.content {
                CardButton(icon: "arrow.up.forward.app", help: L("Открыть", "Open")) { store.open(item) }
                CardButton(icon: "folder", help: L("Показать в Finder", "Show in Finder")) { store.revealInFinder(item) }
            } else if case .link = item.content {
                CardButton(icon: "safari", help: L("Открыть в браузере", "Open in browser")) { store.open(item) }
            }
            CardButton(icon: "square.and.arrow.up", help: L("Отправить по AirDrop", "Send via AirDrop")) { store.airDrop([item]) }
        }
        .padding(3)
        .background(Capsule().fill(.black.opacity(0.55)))
        .padding(.bottom, 2)
    }

    private var title: String {
        switch item.content {
        case .file: url?.lastPathComponent ?? L("Файл", "File")
        case .link(let url): url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url.absoluteString
        case .text: L("Текст", "Text")
        }
    }

    /// "PDF · 2,4 МБ", "Папка", "Ссылка".
    private var subtitle: String {
        switch item.content {
        case .file:
            guard let url else { return "" }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .localizedTypeDescriptionKey])
            if values?.isDirectory == true, values?.isPackage != true { return L("Папка", "Folder") }
            let kind = url.pathExtension.isEmpty ? (values?.localizedTypeDescription ?? L("Файл", "File")) : url.pathExtension.uppercased()
            let size = ShelfStore.size(of: url)
            return size > 0 ? "\(kind) · \(ShelfStore.formatSize(size))" : kind
        case .link: return L("Ссылка", "Link")
        case .text(let text): return plural(text.count, "симв.", "симв.", "симв.", "char", "chars")
        }
    }

    private var help: String {
        switch item.content {
        case .file: L("Клик — просмотр, перетащи — забрать", "Click to preview, drag to take")
        case .link: L("Клик — открыть, перетащи — забрать", "Click to open, drag to take")
        case .text: L("Клик — скопировать, перетащи — забрать", "Click to copy, drag to take")
        }
    }

    private func primaryAction() {
        switch item.content {
        case .file: store.quickLook(item)
        case .link: store.open(item)
        case .text(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
        }
    }
}

private struct CardButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.75))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(isHovering ? 0.22 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}
