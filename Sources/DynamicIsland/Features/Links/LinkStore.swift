import AppKit

struct QuickLink: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var address: String

    /// Accepts "github.com" as well as full URLs; only http(s) so it always opens in the browser.
    var url: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host, host.contains(".") || host == "localhost"
        else { return nil }
        return url
    }

    /// The title if set, otherwise the site's domain.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? address
    }
}

@MainActor
final class LinkStore: ListStore<QuickLink> {
    init() {
        super.init(defaultsKey: "quickLinks")
    }

    /// Opens in the default browser: http(s) URLs are handled by it.
    func open(_ link: QuickLink) {
        guard let url = link.url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Site icons, fetched from the site itself (not a third-party favicon service, which would
/// learn every saved link) and cached on disk.
@MainActor
final class FaviconStore: ObservableObject {
    static let shared = FaviconStore()

    @Published private(set) var icons: [String: NSImage] = [:]
    private var attempted: Set<String> = []

    private static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "DynamicIsland/Favicons")

    func icon(for url: URL?) -> NSImage? {
        url?.host.flatMap { icons[$0] }
    }

    func load(for url: URL?) async {
        guard let url, let host = url.host, !attempted.contains(host) else { return }
        attempted.insert(host)

        let cacheFile = Self.cacheDirectory.appending(path: host)
        if let data = try? Data(contentsOf: cacheFile), let image = NSImage(data: data) {
            icons[host] = image
            return
        }

        // Larger icon first; most sites have one of the two at the root.
        for path in ["apple-touch-icon.png", "favicon.ico"] {
            guard let iconURL = URL(string: "\(url.scheme ?? "https")://\(host)/\(path)") else { continue }
            var request = URLRequest(url: iconURL, timeoutInterval: 8)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.size.width > 0
            else { continue }

            icons[host] = image
            try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: cacheFile)
            return
        }
    }
}
