import AppKit

struct ChatShortcut: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case telegram, whatsapp, imessage, link

        var id: String { rawValue }

        var title: String {
            switch self {
            case .telegram: "Telegram"
            case .whatsapp: "WhatsApp"
            case .imessage: "iMessage"
            case .link: L("Ссылка", "Link")
            }
        }

        var placeholder: String {
            switch self {
            case .telegram: L("@username, +79991234567, ID группы или ссылка на сообщение", "@username, +79991234567, group ID or message link")
            case .whatsapp: "+79991234567"
            case .imessage: L("+79991234567 или email", "+79991234567 or email")
            case .link: "slack://…, discord://…, https://…"
            }
        }
    }

    var id = UUID()
    var name: String
    var kind: Kind
    var value: String

    var url: URL? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        switch kind {
        case .telegram:
            var handle = value
            for prefix in ["https://t.me/", "http://t.me/", "t.me/", "@"] where handle.hasPrefix(prefix) {
                handle.removeFirst(prefix.count)
            }
            // Group/channel by ID: "Copy link" on a message gives t.me/c/<id>/<post>; bots show -100<id>.
            // The post number is dropped so the chat opens where you left off.
            if let channelID = Self.channelID(from: handle) {
                return URL(string: "tg://privatepost?channel=\(channelID)")
            }
            if handle.hasPrefix("+"), Self.isPhoneNumber(handle) {
                return URL(string: "tg://resolve?phone=\(Self.digits(handle))")
            }
            if handle.hasPrefix("+") || handle.hasPrefix("joinchat/") {
                let invite = handle.replacingOccurrences(of: "joinchat/", with: "").trimmingCharacters(in: ["+"])
                return URL(string: "tg://join?invite=\(invite)")
            }
            return Self.encoded(handle).flatMap { URL(string: "tg://resolve?domain=\($0)") }
        case .whatsapp:
            return URL(string: "whatsapp://send?phone=\(Self.digits(value))")
        case .imessage:
            return Self.encoded(value).flatMap { URL(string: "imessage://\($0)") }
        case .link:
            return URL(string: value)
        }
    }

    /// Accepts `c/<id>[/<post>]`, `-100<id>` and a bare `<id>`.
    private static func channelID(from handle: String) -> String? {
        var candidate = handle
        if candidate.hasPrefix("c/") {
            candidate = candidate.dropFirst(2).split(separator: "/").first.map(String.init) ?? ""
        } else if candidate.hasPrefix("-100") {
            candidate.removeFirst(4)
        }
        return !candidate.isEmpty && candidate.allSatisfy(\.isASCII) && candidate.allSatisfy(\.isNumber)
            ? candidate
            : nil
    }

    private static func isPhoneNumber(_ string: String) -> Bool {
        let trimmed = string.hasPrefix("+") ? String(string.dropFirst()) : string
        let allowed = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: " -()"))
        return !trimmed.isEmpty
            && trimmed.unicodeScalars.allSatisfy(allowed.contains)
            && digits(trimmed).count >= 5
    }

    private static func digits(_ string: String) -> String {
        string.filter(\.isNumber)
    }

    private static func encoded(_ string: String) -> String? {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
}

@MainActor
final class ChatStore: ListStore<ChatShortcut> {
    private var iconCache: [String: NSImage] = [:]

    init() {
        super.init(defaultsKey: "chatShortcuts")
    }

    func open(_ chat: ChatShortcut) {
        guard let url = chat.url else { return }
        NSWorkspace.shared.open(url)
    }

    /// Icon of the app that handles the chat's link (Telegram, WhatsApp, ...).
    func appIcon(for chat: ChatShortcut) -> NSImage? {
        guard let url = chat.url else { return nil }
        let key = url.scheme ?? ""
        if let cached = iconCache[key] { return cached }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        iconCache[key] = icon
        return icon
    }
}
