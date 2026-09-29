import SwiftUI

struct ClipboardView: View {
    @ObservedObject var store: ClipboardStore
    /// Index picked with the arrow keys.
    var selection: Int? = nil
    @AppStorage(AppSettings.clipboardHistoryKey) private var isEnabled = true

    /// The translation in progress, and the card it's for.
    @State private var translation: (item: UUID, request: TranslationRequest)?
    @State private var translationProblem: TranslationProblem?
    @State private var problemResetTask: Task<Void, Never>?

    private enum TranslationProblem {
        case needsDownload(String)
        case unsupported
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("Буфер обмена", "Clipboard"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                if let translationProblem {
                    problemView(translationProblem)
                } else if !store.items.isEmpty {
                    Button(L("Очистить", "Clear")) {
                        withAnimation(.easeOut(duration: 0.2)) { store.clear() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 2)

            if !isEnabled {
                MessageView(icon: "doc.on.clipboard", text: L("История буфера выключена", "Clipboard history is off"), action: L("Включить", "Turn on")) {
                    isEnabled = true
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.items.isEmpty {
                MessageView(icon: "doc.on.clipboard", text: L("Скопируй что-нибудь — оно появится здесь", "Copy something and it will show up here"), action: nil, perform: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 8) {
                            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                                ClipboardCard(
                                    item: item,
                                    isCopied: store.lastCopiedID == item.id,
                                    isSelected: selection == index,
                                    isTranslating: translation?.item == item.id,
                                    translate: translatableText(of: item).map { text in { translate(item, text) } },
                                    copy: { withAnimation(.spring(duration: 0.3)) { store.copy(item) } },
                                    remove: { withAnimation(.spring(duration: 0.3)) { store.remove(item) } },
                                    dragProvider: { store.dragProvider(for: item) }
                                )
                                .id(item.id)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .onChange(of: selection) {
                        guard let selection, store.items.indices.contains(selection) else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(store.items[selection].id, anchor: .center) }
                    }
                    // A translation lands at the start of the list; bring it into view.
                    .onChange(of: store.items.first?.id) {
                        guard let first = store.items.first?.id else { return }
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(first, anchor: .leading) }
                    }
                }
            }
        }
        .translating(translation?.request) { request, result in
            guard translation?.request == request else { return }
            translation = nil
            if let result {
                withAnimation(.spring(duration: 0.3)) { store.addCopiedText(result) }
            } else {
                show(.failed)
            }
        }
    }

    /// Plain text only: links and color codes have nothing to translate.
    private func translatableText(of item: ClipboardItem) -> String? {
        guard ClipboardTranslation.isAvailable, case .text(let string) = item.content else { return nil }
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClipboardCard.singleWebURL(text) == nil, PickedColor(hex: text) == nil, text.contains(where: \.isLetter) else {
            return nil
        }
        return text
    }

    private func translate(_ item: ClipboardItem, _ text: String) {
        let request = TranslationRequest(text: text)
        translationProblem = nil
        Task {
            switch await ClipboardTranslation.readiness(for: request) {
            case .ready: translation = (item.id, request)
            case .needsDownload: show(.needsDownload(request.languagesDescription))
            case .unsupported: show(.unsupported)
            }
        }
    }

    private func show(_ problem: TranslationProblem) {
        withAnimation(.easeOut(duration: 0.2)) { translationProblem = problem }
        problemResetTask?.cancel()
        problemResetTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { translationProblem = nil }
        }
    }

    @ViewBuilder
    private func problemView(_ problem: TranslationProblem) -> some View {
        HStack(spacing: 6) {
            switch problem {
            case .needsDownload(let languages):
                Text(L("Для перевода скачай языки: \(languages)", "Download languages to translate: \(languages)"))
                    .foregroundStyle(.orange)
                Button(L("Открыть настройки", "Open Settings"), action: ClipboardTranslation.openLanguageSettings)
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.notchGreen)
            case .unsupported:
                Text(L("Эти языки перевод не поддерживает", "Translation doesn’t support these languages"))
                    .foregroundStyle(.orange)
            case .failed:
                Text(L("Не получилось перевести", "Couldn’t translate"))
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .lineLimit(1)
    }
}

private struct ClipboardCard: View {
    let item: ClipboardItem
    let isCopied: Bool
    let isSelected: Bool
    let isTranslating: Bool
    /// Nil for cards that can't be translated.
    let translate: (() -> Void)?
    let copy: () -> Void
    let remove: () -> Void
    let dragProvider: () -> NSItemProvider

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack(spacing: 4) {
                if let icon = item.sourceAppIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Self.age(of: item.date, now: context.date))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let translate {
                    TranslateButton(isTranslating: isTranslating, action: translate)
                }
                CopyButton(isCopied: isCopied, action: copy)
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(8)
        .frame(width: 128, height: 116)
        // The card is the glass; the copy button on it stays flat (no glass on glass).
        .notchGlass(
            in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            interactive: true,
            fallback: .white.opacity(isHovering ? 0.12 : 0.07)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isCopied ? Color.notchGreen.opacity(0.9) : .white.opacity(isSelected ? 0.6 : 0), lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.2), value: isCopied)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .overlay(alignment: .topTrailing) {
            if isHovering && !isCopied {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(white: 0.3))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help(L("Удалить из истории", "Remove from history"))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: copy)
        .onDrag(dragProvider) {
            switch item.content {
            case .image(let image, _, _): DragPreview(image: image)
            case .text(let text): DragPreview(symbol: "text.alignleft", title: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        .onHover { isHovering = $0 }
        .help(isImage ? L("Клик — скопировать, перетащи — вставить куда нужно", "Click to copy, drag to drop anywhere") : L("Клик — скопировать", "Click to copy"))
    }

    /// Short enough for a narrow card: "сейчас", "5 мин", "2 ч", "3 дн".
    private static func age(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return L("сейчас", "now")
        case ..<3600: return L("\(seconds / 60) мин", "\(seconds / 60)m")
        case ..<86_400: return L("\(seconds / 3600) ч", "\(seconds / 3600)h")
        default: return L("\(seconds / 86_400) дн", "\(seconds / 86_400)d")
        }
    }

    private var isImage: Bool {
        if case .image = item.content { return true }
        return false
    }

    @ViewBuilder
    private var preview: some View {
        switch item.content {
        case .text(let string):
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = Self.singleWebURL(text) {
                LinkPreview(url: url)
            } else if let color = PickedColor(hex: text) {
                ColorPreview(color: color)
            } else {
                TextPreview(text: String(text.prefix(400)))
            }
        case .image(let image, _, _):
            // The card sets the size; the image fills it as an overlay and is cropped.
            // Sizing the image itself with .fill would let a wide screenshot stretch the card.
            Color.clear
                .overlay(
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    /// The whole text is one http(s) address.
    static func singleWebURL(_ text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }
}

/// Short text large, longer text smaller; long text fades out instead of ending mid-line.
private struct TextPreview: View {
    let text: String

    var body: some View {
        let length = text.count
        let isLong = length > 90
        Text(text)
            .font(.system(size: length <= 30 ? 15 : length <= 90 ? 13 : 11, weight: length <= 30 ? .medium : .regular))
            .foregroundStyle(.white.opacity(0.9))
            .lineSpacing(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: isLong ? 0.65 : 1),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

/// A copied address: domain large, the rest of it small.
private struct LinkPreview: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "link")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.notchGreen)
            Text(host)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            if !rest.isEmpty {
                Text(rest)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var host: String {
        let host = url.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var rest: String {
        var rest = url.path
        if let query = url.query { rest += "?" + query }
        return rest == "/" ? "" : rest
    }
}

/// A copied color code (from the eyedropper, or anywhere else): the color itself.
private struct ColorPreview: View {
    let color: PickedColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.color)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 1)
                )
            Text(color.hex)
                .font(.system(size: 13, weight: .semibold).monospaced())
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

/// Translates into Russian (or into English, for Russian text); the result is a new card.
private struct TranslateButton: View {
    let isTranslating: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if isTranslating {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "translate")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(isHovering ? 0.95 : 0.6))
                }
            }
            .frame(width: 22, height: 22)
            .background(Circle().fill(.white.opacity(isHovering ? 0.16 : 0.08)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isTranslating)
        .onHover { isHovering = $0 }
        .help(L("Перевести и скопировать перевод", "Translate and copy the translation"))
    }
}

private struct CopyButton: View {
    let isCopied: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isCopied ? Color.notchGreen : .white.opacity(isHovering ? 0.95 : 0.6))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(isHovering ? 0.16 : 0.08)))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isCopied ? L("Скопировано", "Copied") : L("Скопировать", "Copy"))
    }
}
