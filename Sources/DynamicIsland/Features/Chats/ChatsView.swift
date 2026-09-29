import AppKit
import SwiftUI

struct ChatsView: View {
    @ObservedObject var chats: ChatStore
    /// Shared with the notch: while the form is open, it stays open and takes keyboard focus.
    @Binding var isEditing: Bool
    /// Index picked with the arrow keys.
    var selection: Int? = nil
    @Environment(\.closeNotch) private var closeNotch
    /// The chat being edited; nil while adding a new one.
    @State private var editedChat: ChatShortcut?

    var body: some View {
        content
            // The notch can close the form from outside (collapse, tab switch).
            .onChange(of: isEditing) { if !isEditing { editedChat = nil } }
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            ChatForm(editing: editedChat) { chat in
                withAnimation(.spring(duration: 0.3)) {
                    if editedChat == nil { chats.add(chat) } else { chats.update(chat) }
                }
                isEditing = false
            } cancel: {
                isEditing = false
            }
        } else if chats.items.isEmpty {
            MessageView(icon: "bubble.left.and.bubble.right", text: L("Здесь будут твои чаты", "Your chats will appear here"), action: L("Добавить чат", "Add chat")) {
                isEditing = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TileGrid(
                items: chats.items,
                title: \.name,
                help: { $0.url?.absoluteString ?? "" },
                open: { chat in
                    chats.open(chat)
                    closeNotch()
                },
                edit: { chat in
                    editedChat = chat
                    isEditing = true
                },
                delete: chats.remove,
                move: chats.move(_:to:),
                add: { isEditing = true },
                selectedID: selection.flatMap { chats.items.indices.contains($0) ? chats.items[$0].id : nil }
            ) { chat in
                ZStack(alignment: .bottomTrailing) {
                    InitialsAvatar(name: chat.name, size: 46)
                    if let icon = chats.appIcon(for: chat) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                            .offset(x: 4, y: 4)
                    }
                }
            }
        }
    }
}

/// Adds a new chat, or edits `editing` when it's set.
private struct ChatForm: View {
    let editing: ChatShortcut?
    let save: (ChatShortcut) -> Void
    let cancel: () -> Void

    @State private var name: String
    @State private var kind: ChatShortcut.Kind
    @State private var address: String
    @FocusState private var focusedField: Field?

    private enum Field {
        case name, address
    }

    init(editing: ChatShortcut?, save: @escaping (ChatShortcut) -> Void, cancel: @escaping () -> Void) {
        self.editing = editing
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: editing?.name ?? "")
        _kind = State(initialValue: editing?.kind ?? .telegram)
        _address = State(initialValue: editing?.value ?? "")
    }

    private var chat: ChatShortcut? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep the id when editing so the chat stays in its place.
        let chat = ChatShortcut(id: editing?.id ?? UUID(), name: trimmedName, kind: kind, value: address)
        return trimmedName.isEmpty || chat.url == nil ? nil : chat
    }

    var body: some View {
        // No title row: labels on the left, like the meeting form; the button says what happens.
        NotchFormLayout(
            title: nil,
            submitTitle: editing == nil ? L("Добавить", "Add") : L("Сохранить", "Save"),
            hint: hint,
            canSubmit: chat != nil,
            submit: submit,
            cancel: cancel
        ) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    NotchFormLabel(L("Чат", "Chat"))
                    NotchTextField(placeholder: L("Название, например «Команда»", "Name, e.g. “Team”"), text: $name)
                        .focused($focusedField, equals: .name)
                }
                GridRow {
                    NotchFormLabel(L("Где", "App"))
                    NotchSegmented(options: ChatShortcut.Kind.allCases, title: \.title, selection: $kind)
                }
                GridRow {
                    NotchFormLabel(L("Адрес", "Address"))
                    NotchTextField(placeholder: kind.placeholder, text: $address)
                        .focused($focusedField, equals: .address)
                }
            }
        }
        .onSubmit(submit)
        .onAppear {
            if editing == nil { prefillFromClipboard() }
            // The panel becomes key in the same runloop turn; focus after that.
            DispatchQueue.main.async { focusedField = .name }
        }
    }

    private var hint: Text? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = ChatShortcut(name: "", kind: kind, value: trimmed).url {
            return Text(L("Откроется: \(url.absoluteString)", "Opens: \(url.absoluteString)")).foregroundStyle(.white.opacity(0.45))
        }
        return Text(L("Не получилось распознать адрес", "Couldn’t recognize the address")).foregroundStyle(.red)
    }

    private func submit() {
        if let chat {
            save(chat)
        } else if focusedField == .name {
            focusedField = .address
        }
    }

    /// A copied t.me link or @username is most likely the chat being added.
    private func prefillFromClipboard() {
        guard let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              copied.count < 200,
              copied.contains("t.me/") || (copied.hasPrefix("@") && !copied.contains(" ")),
              ChatShortcut(name: "", kind: .telegram, value: copied).url != nil
        else { return }
        kind = .telegram
        address = copied
    }
}

