import Foundation

/// Everything the app keeps track of, created once at launch and shared by the notch and Settings.
@MainActor
final class AppModel {
    let auth = SpotifyAuth()
    let player: PlayerController
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
        player = PlayerController(auth: auth)
        queue = QueueController(auth: auth, player: player)
        library = LibraryController(auth: auth, player: player)
    }

    /// Saves what's still in memory and cleans up before the app quits.
    func prepareForTermination() {
        recorder.stop()
        notes.save()
        ClipboardStore.removeTemporaryFiles()
    }
}
