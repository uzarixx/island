import AppKit
import SwiftUI

struct LinksView: View {
    @ObservedObject var links: LinkStore
    /// Shared with the notch: while adding, it stays open and takes keyboard focus.
    @Binding var isAdding: Bool
    /// Index picked with the arrow keys.
    var selection: Int? = nil

    @Environment(\.closeNotch) private var closeNotch
    @State private var isDropTargeted = false
    /// The link being edited; nil while adding a new one.
    @State private var editedLink: QuickLink?

    var body: some View {
        content
            // The notch can close the form from outside (collapse, tab switch).
            .onChange(of: isAdding) { if !isAdding { editedLink = nil } }
            // Drag a link from the browser onto the notch to add it right away.
            .dropDestination(for: URL.self) { urls, _ in
                let added = urls.compactMap { url -> QuickLink? in
                    let link = QuickLink(title: "", address: url.absoluteString)
                    return link.url == nil ? nil : link
                }
                guard !added.isEmpty else { return false }
                withAnimation(.spring(duration: 0.3)) { added.forEach(links.add) }
                isAdding = false
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.notchGreen, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .overlay(
                            Label(L("Отпусти, чтобы добавить", "Drop to add"), systemImage: "link.badge.plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.notchGreen)
                        )
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.7)))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isAdding {
            LinkForm(editing: editedLink) { link in
                withAnimation(.spring(duration: 0.3)) {
                    if editedLink == nil { links.add(link) } else { links.update(link) }
                }
                isAdding = false
            } cancel: {
                isAdding = false
            }
        } else if links.items.isEmpty {
            MessageView(icon: "link", text: L("Добавь ссылку или перетащи её сюда", "Add a link or drag one here"), action: L("Добавить ссылку", "Add link")) {
                isAdding = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TileGrid(
                items: links.items,
                title: \.displayTitle,
                help: { $0.url?.absoluteString ?? $0.address },
                open: { link in
                    links.open(link)
                    closeNotch()
                },
                edit: { link in
                    editedLink = link
                    isAdding = true
                },
                delete: links.remove,
                move: links.move(_:to:),
                add: { isAdding = true },
                selectedID: selection.flatMap { links.items.indices.contains($0) ? links.items[$0].id : nil }
            ) { link in
                LinkIcon(link: link, size: 46)
            }
        }
    }
}

/// Adds a new link, or edits `editing` when it's set.
private struct LinkForm: View {
    let editing: QuickLink?
    let save: (QuickLink) -> Void
    let cancel: () -> Void

    @State private var address: String
    @State private var title: String
    @FocusState private var focusedField: Field?

    private enum Field {
        case address, title
    }

    init(editing: QuickLink?, save: @escaping (QuickLink) -> Void, cancel: @escaping () -> Void) {
        self.editing = editing
        self.save = save
        self.cancel = cancel
        _address = State(initialValue: editing?.address ?? "")
        _title = State(initialValue: editing?.title ?? "")
    }

    private var link: QuickLink? {
        // Keep the id when editing so the link stays in its place.
        let link = QuickLink(id: editing?.id ?? UUID(), title: title, address: address)
        return link.url == nil ? nil : link
    }

    var body: some View {
        // No title row: labels on the left, like the meeting form; the button says what happens.
        NotchFormLayout(
            title: nil,
            submitTitle: editing == nil ? L("Добавить", "Add") : L("Сохранить", "Save"),
            hint: hint,
            canSubmit: link != nil,
            submit: submit,
            cancel: cancel
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    NotchFormLabel(L("Адрес", "Address"))
                    NotchTextField(placeholder: L("Например, claude.ai/new", "E.g. claude.ai/new"), text: $address)
                        .focused($focusedField, equals: .address)
                }
                GridRow {
                    NotchFormLabel(L("Название", "Title"))
                    NotchTextField(placeholder: L("Необязательно — иначе будет домен", "Optional — defaults to the domain"), text: $title)
                        .focused($focusedField, equals: .title)
                }
            }
        }
        .onSubmit(submit)
        .onAppear {
            if editing == nil { prefillFromClipboard() }
            // The panel becomes key in the same runloop turn; focus after that.
            // With the address already filled in, Enter saves right away.
            DispatchQueue.main.async { focusedField = address.isEmpty ? .address : .title }
        }
    }

    private var hint: Text? {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let url = QuickLink(title: "", address: address).url {
            return Text(L("Откроется: \(url.absoluteString)", "Opens: \(url.absoluteString)")).foregroundStyle(.white.opacity(0.45))
        }
        return Text(L("Не похоже на адрес сайта", "Doesn’t look like a web address")).foregroundStyle(.red)
    }

    private func submit() {
        if let link { save(link) }
    }

    /// A copied web address is most likely the link being added.
    private func prefillFromClipboard() {
        guard let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              copied.count < 2000,
              copied.hasPrefix("http://") || copied.hasPrefix("https://"),
              QuickLink(title: "", address: copied).url != nil
        else { return }
        address = copied
    }
}

/// The site's icon on a light tile, or a letter avatar until it loads (or if the site has none).
struct LinkIcon: View {
    let link: QuickLink
    let size: CGFloat

    @ObservedObject private var favicons = FaviconStore.shared

    var body: some View {
        Group {
            if let icon = favicons.icon(for: link.url) {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(.white.opacity(0.92))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .padding(size * 0.18)
                    )
            } else {
                InitialsAvatar(name: link.displayTitle, size: size)
            }
        }
        .task(id: link.url) { await favicons.load(for: link.url) }
    }
}
