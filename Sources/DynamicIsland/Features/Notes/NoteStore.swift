import Foundation

/// A single scratchpad, saved as plain text in Application Support shortly after each edit.
@MainActor
final class NoteStore: ObservableObject {
    @Published var text: String {
        didSet { scheduleSave() }
    }

    private var saveTask: Task<Void, Never>?

    static var fileURL: URL {
        AppSettings.dataDirectory.appending(path: "notes.txt")
    }

    init() {
        text = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
    }

    /// Writes right away; also called on quit so the last keystrokes aren't lost.
    func save() {
        saveTask?.cancel()
        saveTask = nil
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Typing saves once it pauses rather than on every keystroke.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            save()
        }
    }
}
