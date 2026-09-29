import Foundation

/// Everything the app keeps track of, created once at launch and shared by the notch and Settings.
@MainActor
final class AppModel {
    let auth = SpotifyAuth()
    let spotify: SpotifyController
    let queue: QueueController
    let library: LibraryController
    let chats = ChatStore()
    let links = LinkStore()
    let meetings = MeetingStore()
    let clipboard = ClipboardStore()
    let shelf = ShelfStore()
    let notes = NoteStore()
    let recorder = VoiceRecorder()
    let batt = BattController()

    init() {
        spotify = SpotifyController(auth: auth)
        queue = QueueController(auth: auth, spotify: spotify)
        library = LibraryController(auth: auth, spotify: spotify)
    }

    /// Saves what's still in memory and cleans up before the app quits.
    func prepareForTermination() {
        recorder.stop()
        notes.save()
        ClipboardStore.removeTemporaryFiles()
    }
}
