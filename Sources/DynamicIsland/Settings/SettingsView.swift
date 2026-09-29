import ServiceManagement
import SwiftUI

/// The sections of Settings, in the sidebar like System Settings.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, tabs, music, meetings, shortcuts, controls

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: L("Основные", "General")
        case .tabs: L("Вкладки", "Tabs")
        case .music: L("Музыка", "Music")
        case .meetings: L("Созвоны", "Meetings")
        case .shortcuts: L("Чаты и ссылки", "Chats & Links")
        case .controls: L("Управление", "Controls")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .tabs: "square.grid.2x2.fill"
        case .music: "music.note"
        case .meetings: "video.fill"
        case .shortcuts: "bubble.left.and.bubble.right.fill"
        case .controls: "keyboard.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: .gray
        case .tabs: .blue
        case .music: .pink
        case .meetings: .green
        case .shortcuts: .teal
        case .controls: .indigo
        }
    }
}

struct SettingsView: View {
    @ObservedObject var auth: SpotifyAuth
    @ObservedObject var chats: ChatStore
    @ObservedObject var links: LinkStore
    @ObservedObject var calendar: CalendarMeetings

    @AppStorage("settingsPane") private var pane = SettingsPane.general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { pane }, set: { if let new = $0 { pane = new } })) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    SettingsIcon(symbol: pane.symbol, color: pane.color)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .formStyle(.grouped)
                .navigationTitle(pane.title)
        }
        .frame(width: 720, height: 560)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralSettings()
        case .tabs: TabsSettings()
        case .music: MusicSettings(auth: auth)
        case .meetings: MeetingsSettings(calendar: calendar)
        case .shortcuts: ShortcutsSettings(chats: chats, links: links)
        case .controls: ControlsSettings()
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var language = AppLanguage.choice
    /// The choice the app was started with; a different one needs a restart.
    private let launchLanguage = AppLanguage.launchChoice
    @AppStorage(AppSettings.hideFromScreenCaptureKey) private var hideFromScreenCapture = true
    @AppStorage(AppSettings.clipboardHistoryKey) private var clipboardHistory = true

    var body: some View {
        Form {
            Section {
                Picker(L("Язык", "Language"), selection: $language) {
                    ForEach(AppLanguage.Choice.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: language) { AppLanguage.choice = language }
                if language != launchLanguage {
                    HStack {
                        Text(L("Язык сменится после перезапуска", "The language changes after a restart"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Перезапустить", "Restart"), action: AppLanguage.relaunch)
                    }
                }
                Toggle(L("Запускать при входе в систему", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let error = launchAtLoginError {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            Section(L("Конфиденциальность", "Privacy")) {
                Toggle(isOn: $hideFromScreenCapture) {
                    Text(L("Скрывать при демонстрации экрана", "Hide during screen sharing"))
                    Text(L("Челка и это окно не попадают в скриншоты, запись и демонстрацию экрана в созвонах", "The notch and this window stay out of screenshots, recordings and screen sharing in calls"))
                }
                Toggle(isOn: $clipboardHistory) {
                    Text(L("История буфера обмена", "Clipboard history"))
                    Text(L("Хранится только в памяти и очищается при выходе. Пароли из менеджеров паролей не сохраняются", "Kept in memory only and cleared on quit. Passwords from password managers aren't saved"))
                }
            }

            Section {
                LabeledContent {
                    Button(L("Показать в Finder", "Show in Finder"), action: showDataDirectory)
                } label: {
                    Text(L("Папка с данными", "Data folder"))
                    Text(AppSettings.dataDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .textSelection(.enabled)
                }
            } header: {
                Text(L("Данные", "Data"))
            } footer: {
                Text(L("Заметки (notes.txt), голосовые заметки (Recordings), свой звук будильника, вход в Spotify и картинки и архивы с полки (Shelf). Чаты, ссылки, созвоны и список полки хранятся в настройках приложения; файлы на полке не копируются — полка только помнит, где они лежат.", "Notes (notes.txt), voice memos (Recordings), the custom alarm sound, the Spotify sign-in, and images and archives from the Shelf. Chats, links, meetings and the shelf list are kept in the app's settings; shelf files aren't copied, the shelf only remembers where they are."))
                    .settingsFooter()
            }

            Section {
                LabeledContent {
                    Button(L("Завершить", "Quit"), role: .destructive) { NSApp.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Text(L("Завершить Island", "Quit Island"))
                    Text(L("Остров закроется полностью. Чтобы вернуть его, открой приложение снова", "The island closes completely. To bring it back, open the app again"))
                }
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // Syncing the toggle below re-triggers onChange; nothing to do when it already matches.
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = SMAppService.mainApp.status == .requiresApproval
                ? L("Разреши запуск в Системных настройках → Основные → Объекты входа", "Allow it in System Settings → General → Login Items")
                : nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        // Reflect what actually happened (e.g. the user has to approve it in System Settings).
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Opens the folder with notes.txt selected, creating the folder if nothing has been saved yet.
    private func showDataDirectory() {
        let notes = NoteStore.fileURL
        if FileManager.default.fileExists(atPath: notes.path) {
            NSWorkspace.shared.activateFileViewerSelecting([notes])
        } else {
            try? FileManager.default.createDirectory(at: AppSettings.dataDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(AppSettings.dataDirectory)
        }
    }
}

// MARK: - Tabs

private struct TabsSettings: View {
    @ObservedObject private var tabSettings = TabSettings.shared
    @State private var draggedTab: NotchTab?

    var body: some View {
        Form {
            Section {
                ForEach(tabSettings.order) { tab in
                    TabSettingsRow(tab: tab, settings: tabSettings)
                        .reorderable(tab, dragged: $draggedTab, move: tabSettings.move)
                }
            } header: {
                HStack {
                    Text(L("Порядок и видимость", "Order and visibility"))
                    Spacer()
                    if !tabSettings.isDefault {
                        Button(L("Как было", "Reset"), action: tabSettings.resetToDefault)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            } footer: {
                Text(L("Перетаскивай вкладки, чтобы поменять порядок. Скрытые вкладки не показываются в челке. Цифры 1–9 на клавиатуре открывают вкладки в этом порядке.", "Drag tabs to reorder them. Hidden tabs don't appear in the notch. Keys 1–9 open tabs in this order."))
                    .settingsFooter()
            }
        }
    }
}

// MARK: - Music

private struct MusicSettings: View {
    @ObservedObject var auth: SpotifyAuth
    @AppStorage(AppSettings.cameraGesturesKey) private var cameraGestures = true
    @AppStorage(AppSettings.liveEqualizerKey) private var liveEqualizer = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $cameraGestures) {
                    Text(L("Жесты у камеры", "Camera gestures"))
                    Text(L("В открытой челке на полоске на уровне камеры: прокрутка вверх/вниз — громкость, свайп влево/вправо — следующий/предыдущий трек. Работает на любой вкладке", "In the open notch, on the strip level with the camera: scroll up/down for volume, swipe left/right for next/previous track. Works on any tab"))
                }
                Toggle(isOn: $liveEqualizer) {
                    Text(L("Эквалайзер в такт музыке", "Live equalizer"))
                    Text(L("Столбики на острове двигаются под настоящий звук плеера, а не по заданному узору. macOS попросит доступ к записи системного аудио и, пока играет музыка, будет показывать фиолетовую точку в строке меню. Звук слушается только из плеера и никуда не записывается", "The bars on the island move to the player's actual sound instead of a preset pattern. macOS will ask for system audio recording access and show a purple dot in the menu bar while music plays. Only the player's audio is captured, and nothing is recorded"))
                }
            } footer: {
                Text(L("Island управляет Spotify и Apple Music напрямую, их собственными командами. Другие плееры — браузер, Яндекс Музыка и т. п. — macOS сторонним приложениям показывать не даёт.", "Island controls Spotify and Apple Music directly, with their own commands. Other players, such as a browser, macOS doesn't expose to other apps."))
                    .settingsFooter()
            }

            SpotifySection(auth: auth)
        }
    }
}

private struct SpotifySection: View {
    @ObservedObject var auth: SpotifyAuth

    var body: some View {
        Section {
            if !auth.isSignedIn {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(L("1. Открой [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) → Create app", "1. Open [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) → Create app")))
                    HStack(spacing: 6) {
                        Text("2. Redirect URI:")
                        Text(SpotifyAuth.redirectURI)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(SpotifyAuth.redirectURI, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(L("Скопировать", "Copy"))
                    }
                    Text(L("3. В разделе APIs отметь Web API и сохрани", "3. Under APIs, check Web API and save"))
                    Text(L("4. Скопируй Client ID из настроек приложения сюда", "4. Copy the Client ID from the app's settings here"))
                }
                .font(.callout)

                InputField(title: "Client ID", text: $auth.clientID, prompt: L("Вставь Client ID из Spotify Dashboard", "Paste the Client ID from Spotify Dashboard"), monospaced: true)
            }

            HStack {
                if auth.isSignedIn {
                    Label(L("Подключено", "Connected"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button(L("Отключить", "Disconnect"), action: auth.signOut)
                } else if auth.isSigningIn {
                    ProgressView().controlSize(.small)
                    Text(L("Подтверди доступ в браузере…", "Confirm access in your browser…"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Отмена", "Cancel"), action: auth.signOut)
                } else {
                    Spacer()
                    Button(L("Подключить Spotify", "Connect Spotify"), action: auth.signIn)
                        .disabled(!auth.hasClientID)
                }
            }

            if auth.needsReconnect {
                HStack {
                    Text(L("Чтобы работали лайки, повтор одного трека и плейлисты, переподключи Spotify: нужны новые разрешения", "Reconnect Spotify for likes, repeat one and playlists: new permissions are needed"))
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(L("Переподключить", "Reconnect")) {
                        auth.signOut()
                        auth.signIn()
                    }
                }
            }

            if let error = auth.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text(L("Без подключения Spotify работает как обычный плеер. С подключением рядом с ним появляются очередь, плейлисты, поиск и лайки.", "Without connecting, Spotify works as a plain player. Once connected, the queue, playlists, search and likes appear next to it."))
                .settingsFooter()
        }
    }
}

// MARK: - Meetings

private struct MeetingsSettings: View {
    @ObservedObject var calendar: CalendarMeetings

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { calendar.isEnabled && calendar.access == .granted },
                    set: { enabled in enabled ? calendar.connect() : (calendar.isEnabled = false) }
                )) {
                    Text(L("Созвоны из Календаря", "Meetings from Calendar"))
                    Text(L("События из приложения «Календарь» (iCloud, Google, Exchange) на неделю вперёд. Ссылка на Zoom, Meet, Teams, Телемост и другие находится сама", "Events from the Calendar app (iCloud, Google, Exchange) for the week ahead. Zoom, Meet, Teams, Telemost and other links are found automatically"))
                }
                if calendar.access == .denied {
                    HStack {
                        Text(L("Нет доступа к Календарю: включи Island в настройках конфиденциальности", "No Calendar access: turn on Island in Privacy settings"))
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(L("Открыть", "Open"), action: calendar.openPrivacySettings)
                    }
                }
                if calendar.isEnabled && calendar.access == .granted {
                    Toggle(isOn: $calendar.onlyWithLinks) {
                        Text(L("Только со ссылкой на созвон", "Only with a meeting link"))
                        Text(L("Скрывать события без ссылки на Zoom, Meet, Teams и т. п. — обеды, фокус-блоки, напоминания", "Hide events without a Zoom, Meet, Teams, etc. link: lunches, focus blocks, reminders"))
                    }
                    if calendar.hiddenCount > 0 {
                        LabeledContent(L("Скрытые события: \(calendar.hiddenCount)", "Hidden events: \(calendar.hiddenCount)")) {
                            Button(L("Показать снова", "Show again"), action: calendar.showHiddenEvents)
                        }
                    }
                }
            } header: {
                Text(L("Календарь", "Calendar"))
            }

            if calendar.isEnabled && calendar.access == .granted && !calendar.calendars.isEmpty {
                Section(L("Календари: \(calendar.calendars.filter(calendar.isIncluded).count) из \(calendar.calendars.count)", "Calendars: \(calendar.calendars.filter(calendar.isIncluded).count) of \(calendar.calendars.count)")) {
                    ForEach(calendar.calendars) { item in
                        Toggle(isOn: Binding(get: { calendar.isIncluded(item) }, set: { calendar.setIncluded(item, $0) })) {
                            HStack(spacing: 6) {
                                Circle().fill(Color(nsColor: item.color)).frame(width: 8, height: 8)
                                Text(item.title)
                                Text(item.account).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                if calendar.isEnabled && calendar.access == .granted {
                    Picker(L("Напоминать", "Remind"), selection: $calendar.leadMinutes) {
                        Text(L("В начале", "At start")).tag(0)
                        ForEach([5, 10, 15], id: \.self) { Text(L("За \($0) мин", "\($0) min before")).tag($0) }
                    }
                    Picker(L("Как напоминать", "Alert style"), selection: $calendar.alertStyle) {
                        ForEach(Meeting.AlertStyle.allCases) { Text($0.title).tag($0) }
                    }
                }
                AlarmSoundPicker()
            } header: {
                Text(L("Напоминания", "Reminders"))
            } footer: {
                Text(L("Звук играет у всех созвонов с напоминанием «Будильник». Свой звук — любой аудиофайл: mp3, m4a, wav, aiff. Для отдельного события из Календаря способ напоминания меняется в челке, при наведении на него.", "The sound plays for all meetings with the Alarm alert. A custom sound can be any audio file: mp3, m4a, wav, aiff. To change the alert for a single Calendar event, hover over it in the notch."))
                    .settingsFooter()
            }
        }
    }
}

// MARK: - Chats and links

private struct ShortcutsSettings: View {
    @ObservedObject var chats: ChatStore
    @ObservedObject var links: LinkStore
    @State private var draggedID: UUID?

    var body: some View {
        Form {
            Section {
                if chats.items.isEmpty {
                    Text(L("Пока пусто — добавь чат во вкладке «Чаты» на острове", "Nothing here yet: add a chat in the Chats tab on the island"))
                        .foregroundStyle(.secondary)
                }
                ForEach(chats.items) { chat in
                    ChatSettingsRow(chat: chat, store: chats)
                        .reorderable(chat.id, dragged: $draggedID, move: chats.move)
                }
            } header: {
                Text(L("Чаты", "Chats"))
            }

            Section {
                if links.items.isEmpty {
                    Text(L("Пока пусто — добавь ссылку во вкладке «Ссылки» на острове", "Nothing here yet: add a link in the Links tab on the island"))
                        .foregroundStyle(.secondary)
                }
                ForEach(links.items) { link in
                    LinkSettingsRow(link: link, store: links)
                        .reorderable(link.id, dragged: $draggedID, move: links.move)
                }
            } header: {
                Text(L("Ссылки", "Links"))
            } footer: {
                Text(L("Перетаскивай, чтобы поменять порядок: так же они стоят на острове.", "Drag to reorder: the island shows them in the same order."))
                    .settingsFooter()
            }
        }
    }
}

// MARK: - Controls

private struct ControlsSettings: View {
    @ObservedObject private var shortcuts = ShortcutCenter.shared
    @ObservedObject private var middleClick = MiddleClickEmulator.shared
    @AppStorage(AppSettings.middleClickKey) private var middleClickEnabled = true
    @AppStorage(AppSettings.middleClickTapKey) private var middleClickTap = true
    /// The MiddleClick app does the same; both at once would make every middle click double.
    @State private var isMiddleClickAppRunning = false

    private static let middleClickAppID = "art.ginzburg.MiddleClick"

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases) { action in
                    ShortcutRow(action: action, center: shortcuts)
                }
            } header: {
                Text(L("Сочетания клавиш", "Keyboard shortcuts"))
            } footer: {
                Text(L("В открытом острове: цифры 1–9 и ⇥ переключают вкладки, Esc закрывает.", "In the open island: keys 1–9 and ⇥ switch tabs, Esc closes it."))
                    .settingsFooter()
            }

            Section(L("Трекпад", "Trackpad")) {
                Toggle(isOn: $middleClickEnabled) {
                    Text(L("Средний клик тремя пальцами", "Three-finger middle click"))
                    Text(L("Нажатие тремя пальцами на трекпаде — как клик колёсиком: открыть ссылку в новой вкладке, закрыть вкладку", "A three-finger click on the trackpad acts as a middle click: open a link in a new tab, close a tab"))
                }
                if middleClickEnabled {
                    Toggle(L("Также лёгким касанием, без нажатия", "Also with a light tap"), isOn: $middleClickTap)
                    if !middleClick.isTrusted {
                        HStack {
                            Text(L("Нужен доступ в «Универсальном доступе»: включи там Island", "Needs Accessibility access: turn on Island there"))
                                .font(.callout)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button(L("Открыть", "Open"), action: middleClick.openAccessibilitySettings)
                        }
                    }
                    if isMiddleClickAppRunning {
                        HStack {
                            Text(L("Запущена программа MiddleClick — клики будут двойными", "MiddleClick is running, so clicks will be doubled"))
                                .font(.callout)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button(L("Завершить MiddleClick", "Quit MiddleClick"), action: quitMiddleClickApp)
                        }
                    }
                }
            }
        }
        .onAppear(perform: checkMiddleClickApp)
        .onChange(of: middleClickEnabled) { checkMiddleClickApp() }
    }

    private func checkMiddleClickApp() {
        isMiddleClickAppRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.middleClickAppID).isEmpty
    }

    private func quitMiddleClickApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.middleClickAppID).forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { checkMiddleClickApp() }
    }
}

private extension View {
    func settingsFooter() -> some View {
        font(.caption).foregroundStyle(.secondary)
    }
}
