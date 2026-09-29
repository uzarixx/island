import AppKit
import AVFoundation

struct VoiceMemo: Identifiable, Equatable {
    let url: URL
    let date: Date
    /// Seconds.
    let duration: Double

    var id: URL { url }
}

/// Records voice memos to m4a files in the app's data folder and plays them back.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    /// Newest first.
    @Published private(set) var memos: [VoiceMemo] = []
    /// When the current recording started; nil while not recording.
    @Published private(set) var recordingSince: Date?
    @Published private(set) var playingURL: URL?
    @Published private(set) var microphoneDenied = false

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?

    static var directory: URL {
        AppSettings.dataDirectory.appending(path: "Recordings")
    }

    override init() {
        super.init()
        loadMemos()
    }

    var isRecording: Bool { recordingSince != nil }

    func toggleRecording() {
        if isRecording { stop() } else { start() }
    }

    func start() {
        guard !isRecording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.microphoneDenied = !granted
                        if granted { self.beginRecording() }
                    }
                }
            }
        default:
            microphoneDenied = true
        }
    }

    func stop() {
        guard let recorder else { return }
        let url = recorder.url
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        recordingSince = nil
        // A stray tap on the button shouldn't leave an empty memo behind.
        if duration < 0.5 {
            try? FileManager.default.removeItem(at: url)
        }
        loadMemos()
    }

    func togglePlayback(_ memo: VoiceMemo) {
        if playingURL == memo.url {
            stopPlayback()
            return
        }
        stopPlayback()
        guard let player = try? AVAudioPlayer(contentsOf: memo.url) else { return }
        player.delegate = self
        player.play()
        self.player = player
        playingURL = memo.url
    }

    /// Moves the file to the Trash rather than deleting it outright.
    func delete(_ memo: VoiceMemo) {
        if playingURL == memo.url { stopPlayback() }
        try? FileManager.default.trashItem(at: memo.url, resultingItemURL: nil)
        memos.removeAll { $0.url == memo.url }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private func beginRecording() {
        let directory = Self.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = directory.appending(path: L("Голосовая заметка \(formatter.string(from: Date())).m4a", "Voice note \(formatter.string(from: Date())).m4a"))

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else {
            NSLog("Couldn't start recording to \(url.path)")
            return
        }
        stopPlayback()
        self.recorder = recorder
        recordingSince = Date()
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    private func loadMemos() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        memos = files
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url in
                guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return VoiceMemo(url: url, date: date, duration: player.duration)
            }
            .sorted { $0.date > $1.date }
    }
}

extension VoiceRecorder: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let url = player.url
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if self.playingURL == url { self.stopPlayback() }
            }
        }
    }
}
