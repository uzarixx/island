import AppKit
import SwiftUI

struct NotesView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var recorder: VoiceRecorder
    /// Shared with the notch: while typing, it stays open and takes keyboard input.
    @Binding var isEditing: Bool
    /// Opened from the keyboard: start typing right away.
    let autoFocus: Bool

    @FocusState private var isFocused: Bool
    /// Text removed by "Очистить", kept for a moment so it can be brought back.
    @State private var clearedText: String?
    @State private var restoreTask: Task<Void, Never>?
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            TextEditor(text: $store.text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($isFocused)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
                .overlay(alignment: .topLeading) {
                    if store.text.isEmpty && !isFocused {
                        // Lines up with the editor's first line.
                        Text(L("Пиши что угодно — сохраняется само", "Write anything — it saves automatically"))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.leading, 9)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
                .notchGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if !recorder.memos.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(recorder.memos) { memo in
                            MemoChip(
                                memo: memo,
                                isPlaying: recorder.playingURL == memo.url,
                                play: { recorder.togglePlayback(memo) },
                                delete: { withAnimation(.spring(duration: 0.3)) { recorder.delete(memo) } }
                            )
                        }
                    }
                }
                .scrollIndicators(.never)
                .frame(height: 24)
            }
        }
        // Typing pins the notch open and makes the panel key, like the add forms do.
        .onChange(of: isFocused) { if isFocused { isEditing = true } }
        // The notch can end editing from outside (collapse, tab switch).
        .onChange(of: isEditing) { if !isEditing { isFocused = false } }
        .onAppear {
            // The panel becomes key in the same runloop turn; focus after that.
            if autoFocus { DispatchQueue.main.async { isFocused = true } }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(L("Заметки", "Notes"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            if recorder.microphoneDenied {
                Text(L("Нет доступа к микрофону", "No microphone access"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                HeaderButton(title: L("Разрешить", "Allow"), action: recorder.openMicrophoneSettings)
            } else {
                RecordButton(recordingSince: recorder.recordingSince, action: recorder.toggleRecording)
            }
            Spacer()
            if clearedText != nil {
                HeaderButton(title: L("Вернуть", "Restore"), action: restore)
            } else if !store.text.isEmpty {
                HeaderButton(title: isCopied ? L("Скопировано", "Copied") : L("Скопировать", "Copy"), action: copy)
                HeaderButton(title: L("Очистить", "Clear"), action: clear)
            }
        }
        .padding(.horizontal, 2)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.text, forType: .string)
        isCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            isCopied = false
        }
    }

    /// No confirmation: "Вернуть" undoes it for a few seconds instead.
    private func clear() {
        clearedText = store.text
        store.text = ""
        restoreTask?.cancel()
        restoreTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            clearedText = nil
        }
    }

    private func restore() {
        restoreTask?.cancel()
        if let clearedText, store.text.isEmpty { store.text = clearedText }
        clearedText = nil
    }
}

private struct RecordButton: View {
    let recordingSince: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let recordingSince {
                TimelineView(.periodic(from: recordingSince, by: 1)) { context in
                    Label(L("Стоп · \(formatTime(context.date.timeIntervalSince(recordingSince)))", "Stop · \(formatTime(context.date.timeIntervalSince(recordingSince)))"), systemImage: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                Label(L("Голосовая заметка", "Voice note"), systemImage: "mic.fill")
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .help(recordingSince == nil ? L("Записать голосовую заметку", "Record a voice note") : L("Остановить запись", "Stop recording"))
    }
}

/// A recorded memo: click plays it, dragging it into a chat sends the file.
private struct MemoChip: View {
    let memo: VoiceMemo
    let isPlaying: Bool
    let play: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isPlaying ? Color.notchGreen : .white.opacity(0.8))
            Text(label)
                .foregroundStyle(.white.opacity(0.85))
            Text(formatTime(memo.duration))
                .foregroundStyle(.white.opacity(0.45))
            if isHovering {
                Button(action: delete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(L("В корзину", "Move to Trash"))
            }
        }
        .font(.system(size: 10, weight: .medium).monospacedDigit())
        .padding(.horizontal, 9)
        .frame(height: 22)
        .notchGlass(in: Capsule(), interactive: true)
        .contentShape(Capsule())
        .onTapGesture(perform: play)
        .onDrag { NSItemProvider(contentsOf: memo.url) ?? NSItemProvider() } preview: {
            DragPreview(symbol: "waveform", title: "\(label) · \(formatTime(memo.duration))")
        }
        .onHover { isHovering = $0 }
        .help(L("Клик — прослушать, перетащи в чат — отправить файл", "Click to play, drag to a chat to send the file"))
    }

    /// The time for today's memos, the date for older ones.
    private var label: String {
        Calendar.current.isDateInToday(memo.date)
            ? memo.date.formatted(.dateTime.hour().minute())
            : memo.date.formatted(.dateTime.day().month(.abbreviated).locale(.app))
    }
}

private struct HeaderButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
    }
}
