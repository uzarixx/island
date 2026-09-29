import Carbon.HIToolbox
import SwiftUI

/// A global shortcut: its name, and a field that records a new one when clicked.
struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var center: ShortcutCenter

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Text(action.title)
                Spacer()
                Button(action: toggleRecording) {
                    Text(fieldTitle)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(isRecording ? Color.accentColor : center.combo(for: action) == nil ? .secondary : .primary)
                        .frame(minWidth: 130)
                }
                .help(isRecording ? L("Нажми сочетание: ⌫ — выключить, Esc — отмена", "Press a shortcut: ⌫ to turn off, Esc to cancel") : L("Кликни и нажми новое сочетание", "Click and press a new shortcut"))
                if center.combo(for: action) != action.defaultCombo, !isRecording {
                    Button {
                        center.setCombo(action.defaultCombo, for: action)
                        problem = nil
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Вернуть \(action.defaultCombo.description)", "Reset to \(action.defaultCombo.description)"))
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
            } else if center.unavailable.contains(action) {
                Text(L("Это сочетание занято другим приложением, выбери другое", "Another app uses this shortcut, choose a different one")).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var fieldTitle: String {
        if isRecording { return L("Нажми сочетание…", "Press a shortcut…") }
        return center.combo(for: action)?.description ?? L("Выключено", "Off")
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        problem = nil
        isRecording = true
        // Otherwise pressing the current shortcut would fire it instead of being recorded.
        center.setPaused(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            record(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        center.setPaused(false)
    }

    private func record(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where modifiers.isEmpty:
            stopRecording()
            return
        case kVK_Delete where modifiers.isEmpty, kVK_ForwardDelete where modifiers.isEmpty:
            center.setCombo(nil, for: action)
            stopRecording()
            return
        default:
            break
        }

        let combo = KeyCombo(event: event)
        guard combo.isValidGlobalShortcut else {
            problem = L("Нужна клавиша-модификатор: ⌃, ⌥ или ⌘", "Needs a modifier key: ⌃, ⌥ or ⌘")
            NSSound.beep()
            return
        }
        if let other = center.conflict(for: combo, excluding: action) {
            problem = L("Уже используется: «\(other.title)»", "Already used by “\(other.title)”")
            NSSound.beep()
            return
        }
        problem = nil
        stopRecording()
        center.setCombo(combo, for: action)
    }
}

struct AlarmSoundPicker: View {
    @AppStorage(AlarmSound.settingKey) private var setting = AlarmSound.defaultSetting
    @State private var preview: NSSound?
    @State private var isPlaying = false

    var body: some View {
        HStack {
            Picker(L("Звук будильника", "Alarm sound"), selection: $setting) {
                Section(L("Рингтоны", "Ringtones")) {
                    ForEach(AlarmSound.ringtones, id: \.setting) { ringtone in
                        Text(ringtone.name).tag(ringtone.setting)
                    }
                }
                Section(L("Системные сигналы", "System sounds")) {
                    ForEach(AlarmSound.systemNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                if AlarmSound.isCustom(setting) {
                    Divider()
                    Text(L("Свой: \(AlarmSound.displayName(setting))", "Custom: \(AlarmSound.displayName(setting))")).tag(setting)
                }
            }
            .onChange(of: setting) {
                // Hear the new choice right away.
                stopPreview()
                playPreview()
            }

            Button {
                isPlaying ? stopPreview() : playPreview()
            } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 14)
            }
            .help(isPlaying ? L("Остановить", "Stop") : L("Прослушать", "Play"))

            Button(L("Свой файл…", "Custom file…")) {
                if let custom = AlarmSound.chooseCustomFile() {
                    setting = custom
                }
            }
        }
        .onDisappear(perform: stopPreview)
    }

    private func playPreview() {
        let sound = AlarmSound.sound(for: setting)
        sound?.play()
        preview = sound
        isPlaying = sound != nil
        // Flip the button back once a short sound has finished.
        let duration = sound?.duration ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.1) {
            if preview === sound, sound?.isPlaying == false { isPlaying = false }
        }
    }

    private func stopPreview() {
        preview?.stop()
        preview = nil
        isPlaying = false
    }
}

/// Label above a bordered field: inside a grouped Form a plain TextField has no visible border.
struct InputField: View {
    let title: String
    @Binding var text: String
    let prompt: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(title, text: $text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
        }
    }
}

struct LinkSettingsRow: View {
    let link: QuickLink
    @ObservedObject var store: LinkStore

    var body: some View {
        HStack(spacing: 10) {
            LinkIcon(link: link, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.displayTitle)
                Text(link.url?.absoluteString ?? link.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button { store.open(link) } label: { Image(systemName: "arrow.up.forward.app") }
                .help(L("Открыть", "Open"))
            Button { store.remove(link) } label: { Image(systemName: "trash") }
                .help(L("Удалить", "Delete"))
            DragHandle()
        }
        .buttonStyle(.borderless)
    }
}

struct ChatSettingsRow: View {
    let chat: ChatShortcut
    @ObservedObject var store: ChatStore

    var body: some View {
        HStack(spacing: 10) {
            InitialsAvatar(name: chat.name, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(chat.name)
                Text("\(chat.kind.title) · \(chat.value)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { store.open(chat) } label: { Image(systemName: "arrow.up.forward.app") }
                .help(L("Открыть", "Open"))
            Button { store.remove(chat) } label: { Image(systemName: "trash") }
                .help(L("Удалить", "Delete"))
            DragHandle()
        }
        .buttonStyle(.borderless)
    }
}

struct TabSettingsRow: View {
    let tab: NotchTab
    @ObservedObject var settings: TabSettings

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: tab.icon, color: settings.isVisible(tab) ? .accentColor : .gray)
            Text(tab.title)
                .foregroundStyle(settings.isVisible(tab) ? .primary : .secondary)
            if tab == .battery, !BattController.isInstalled {
                Text(L("нужен batt", "requires batt"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { settings.isVisible(tab) }, set: { settings.setVisible(tab, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(settings.isVisible(tab) && !settings.canHide(tab))
                .help(settings.canHide(tab) || !settings.isVisible(tab) ? L("Показывать в челке", "Show in the notch") : L("Хотя бы одна вкладка должна остаться", "At least one tab must stay visible"))
            DragHandle()
        }
        .buttonStyle(.borderless)
    }
}

/// A symbol on a colored rounded square, like the icons in System Settings.
struct SettingsIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.gradient))
    }
}
