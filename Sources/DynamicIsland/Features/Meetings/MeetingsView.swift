import AppKit
import SwiftUI

struct MeetingsView: View {
    @ObservedObject var store: MeetingStore
    @ObservedObject var calendar: CalendarMeetings
    /// Shared with the notch: while the form is open, it stays open and takes keyboard focus.
    @Binding var isEditing: Bool
    /// Index picked with the arrow keys, in `store.upcoming()` order.
    var selection: Int? = nil
    @Environment(\.closeNotch) private var closeNotch
    /// The meeting being edited; nil while adding a new one.
    @State private var editedMeeting: Meeting?

    var body: some View {
        content
            // The notch can close the form from outside (collapse, tab switch).
            .onChange(of: isEditing) { if !isEditing { editedMeeting = nil } }
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            MeetingForm(editing: editedMeeting) { meeting in
                withAnimation(.spring(duration: 0.3)) {
                    if editedMeeting == nil { store.add(meeting) } else { store.update(meeting) }
                }
                isEditing = false
            } cancel: {
                isEditing = false
            }
        } else if store.allMeetings.isEmpty && calendar.lastHidden == nil {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            list
        }
    }

    /// Suggests the Calendar first: most meetings are already there.
    @ViewBuilder
    private var emptyState: some View {
        if calendar.isEnabled && calendar.access == .granted {
            MessageView(
                icon: "calendar",
                text: calendar.onlyWithLinks ? L("На неделю вперёд созвонов со ссылкой нет", "No meetings with links in the next week") : L("На неделю вперёд событий нет", "No events in the next week"),
                action: L("Добавить вручную", "Add manually")
            ) {
                isEditing = true
            }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "video")
                    Text(L("Созвоны из Календаря или свои — напомню заранее", "Meetings from Calendar or your own, with reminders"))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                HStack(spacing: 8) {
                    NotchFormButton(title: calendar.access == .denied ? L("Разрешить доступ к Календарю", "Allow Calendar access") : L("Подключить Календарь", "Connect Calendar"), isPrimary: true, tint: Color.notchGreen) {
                        calendar.connect()
                    }
                    NotchFormButton(title: L("Добавить вручную", "Add manually")) { isEditing = true }
                }
                if calendar.access == .denied {
                    Text(L("Доступ выключен в Системных настройках → Конфиденциальность → Календари", "Access is off in System Settings → Privacy & Security → Calendars"))
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Refresh "через 5 мин" and the join button's state.
            TimelineView(.periodic(from: .now, by: 20)) { context in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(store.upcoming(now: context.date).enumerated()), id: \.element.meeting.id) { index, item in
                                MeetingRow(
                                    meeting: item.meeting,
                                    start: item.start,
                                    now: context.date,
                                    isSelected: selection == index,
                                    join: {
                                    store.join(item.meeting)
                                    closeNotch()
                                },
                                    edit: {
                                        editedMeeting = item.meeting
                                        isEditing = true
                                    },
                                    toggleAlert: {
                                        var meeting = item.meeting
                                        meeting.alertStyle = meeting.alertStyle == .alarm ? .notification : .alarm
                                        store.update(meeting)
                                    },
                                    delete: { withAnimation(.spring(duration: 0.3)) { store.remove(item.meeting) } }
                                )
                                .id(index)
                            }
                            HStack(spacing: 0) {
                                AddRow { isEditing = true }
                                if !(calendar.isEnabled && calendar.access == .granted) {
                                    AddRow(title: L("Подключить Календарь", "Connect Calendar"), icon: "calendar.badge.plus", action: calendar.connect)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .onChange(of: selection) {
                        guard let selection else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(selection) }
                    }
                }
            }

            if let hidden = calendar.lastHidden {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                    Text(L("«\(hidden.title)» скрыт — в Календаре он остался", "“\(hidden.title)” hidden — it’s still in Calendar"))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(L("Вернуть", "Undo")) {
                        withAnimation(.spring(duration: 0.3)) { calendar.undoHide() }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.notchGreen)
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 6)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if calendar.isEnabled && calendar.access == .denied {
                HStack(spacing: 6) {
                    Text(L("Нет доступа к Календарю", "No Calendar access"))
                        .foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button(L("Настройки", "Settings"), action: calendar.openPrivacySettings)
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.notchGreen)
                }
                .font(.system(size: 10))
                .padding(.horizontal, 6)
            }
            if store.notificationsDenied {
                HStack(spacing: 6) {
                    Text(L("Уведомления для утилиты выключены", "Notifications are off for this app"))
                        .foregroundStyle(.orange)
                    Spacer(minLength: 4)
                    Button(L("Настройки", "Settings"), action: store.openNotificationSettings)
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.notchGreen)
                }
                .font(.system(size: 10))
                .padding(.horizontal, 6)
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting
    let start: Date?
    let now: Date
    let isSelected: Bool
    let join: () -> Void
    let edit: () -> Void
    /// Calendar events: switches between a notification and an alarm (they can't be edited here).
    let toggleAlert: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    private var calendarColor: Color? {
        meeting.calendarEvent.map { event in event.colorHex.flatMap { PickedColor(hex: $0)?.color } ?? .white.opacity(0.5) }
    }

    /// From 15 minutes before the start until it's gone from the list.
    private var isJoinable: Bool {
        guard let start else { return false }
        return start.timeIntervalSince(now) < 15 * 60
    }

    var body: some View {
        HStack(spacing: 10) {
            if let calendarColor {
                Capsule()
                    .fill(calendarColor)
                    .frame(width: 3, height: 26)
                    .padding(.trailing, -4)
            }
            Text(meeting.date, format: .dateTime.hour().minute())
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(start == nil ? .white.opacity(0.35) : .white)
                .frame(width: 46, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(start == nil ? 0.4 : 1))
                HStack(spacing: 4) {
                    Image(systemName: meeting.alertStyle == .alarm ? "alarm" : "bell")
                    if meeting.calendarEvent != nil { Image(systemName: "calendar") }
                    Text(subtitle)
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
            }
            .lineLimit(1)

            Spacer(minLength: 4)

            if isHovering {
                if meeting.calendarEvent != nil {
                    RowIconButton(
                        systemName: meeting.alertStyle == .alarm ? "bell" : "alarm",
                        help: meeting.alertStyle == .alarm ? L("Напомнить уведомлением", "Remind with a notification") : L("Напомнить будильником", "Remind with an alarm"),
                        action: toggleAlert
                    )
                    RowIconButton(systemName: "eye.slash", help: L("Скрыть (в Календаре останется)", "Hide (stays in Calendar)"), action: delete)
                } else {
                    RowIconButton(systemName: "pencil", help: L("Изменить", "Edit"), action: edit)
                    RowIconButton(systemName: "trash", help: L("Удалить", "Delete"), action: delete)
                }
            }
            if meeting.url != nil {
                Button(action: join) {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                        if isJoinable { Text(L("Подключиться", "Join")) }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isJoinable ? .black : .white.opacity(0.8))
                    .padding(.horizontal, isJoinable ? 10 : 8)
                    .frame(height: 22)
                    .background(Capsule().fill(isJoinable ? Color.notchGreen : .white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(meeting.url?.absoluteString ?? "")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // The row is the glass card; the join button inside stays flat (no glass on glass).
        .notchGlass(
            in: RoundedRectangle(cornerRadius: 10, style: .continuous),
            fallback: .white.opacity(isHovering ? 0.08 : 0.04)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(isSelected ? 0.5 : 0), lineWidth: 1.5)
        )
        .onHover { isHovering = $0 }
    }

    /// "По будням · через 12 мин", "Работа · завтра", "прошёл".
    private var subtitle: String {
        let source = meeting.calendarEvent.map { $0.calendarTitle.isEmpty ? L("Календарь", "Calendar") : $0.calendarTitle } ?? meeting.recurrence.title
        guard let start else { return L("\(source) · прошёл", "\(source) · ended") }
        let interval = start.timeIntervalSince(now)
        let when: String
        if interval <= 0 {
            when = L("идёт \(max(1, Int(-interval / 60))) мин", "started \(max(1, Int(-interval / 60))) min ago")
        } else if interval < 60 * 60 {
            when = L("через \(max(1, Int(interval / 60))) мин", "in \(max(1, Int(interval / 60))) min")
        } else if Calendar.current.isDateInToday(start) {
            when = L("сегодня", "today")
        } else if Calendar.current.isDateInTomorrow(start) {
            when = L("завтра", "tomorrow")
        } else {
            when = start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.app))
        }
        return "\(source) · \(when)"
    }
}

private struct RowIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct AddRow: View {
    var title = L("Добавить созвон", "Add meeting")
    var icon = "plus"
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(isHovering ? 0.9 : 0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Adds a new meeting, or edits `editing` when it's set.
private struct MeetingForm: View {
    let editing: Meeting?
    let save: (Meeting) -> Void
    let cancel: () -> Void

    @State private var title: String
    @State private var link: String
    /// The date part; only matters for one-off and weekly meetings.
    @State private var day: Date
    @State private var hour: Int
    @State private var minute: Int
    @State private var recurrence: Meeting.Recurrence
    @State private var leadMinutes: Int
    @State private var alertStyle: Meeting.AlertStyle
    @FocusState private var focusedField: Field?

    private enum Field {
        case title, link
    }

    private static let leadOptions = [0, 5, 10, 15]
    /// "Вс", "Пн", ... indexed by calendar weekday - 1.
    private static let weekdaySymbols: [String] = {
        var calendar = Calendar.current
        calendar.locale = .app
        return calendar.shortWeekdaySymbols
    }()
    /// Calendar weekdays (1 = Sunday) in Monday-first order.
    private static let weekdayOptions = [2, 3, 4, 5, 6, 7, 1]

    init(editing: Meeting?, save: @escaping (Meeting) -> Void, cancel: @escaping () -> Void) {
        self.editing = editing
        self.save = save
        self.cancel = cancel
        let calendar = Calendar.current
        let date = editing?.date ?? Self.roundedNow()
        _title = State(initialValue: editing?.title ?? "")
        _link = State(initialValue: editing?.link ?? "")
        _day = State(initialValue: calendar.startOfDay(for: date))
        _hour = State(initialValue: calendar.component(.hour, from: date))
        _minute = State(initialValue: calendar.component(.minute, from: date))
        _recurrence = State(initialValue: editing?.recurrence ?? .weekdays)
        _leadMinutes = State(initialValue: editing?.leadMinutes ?? 5)
        _alertStyle = State(initialValue: editing?.alertStyle ?? .notification)
    }

    /// A new meeting starts at the current time rounded up to 5 minutes (18:07 → 18:10),
    /// so a one-off isn't already in the past. Crossing midnight moves it to tomorrow too.
    private static func roundedNow(step: Int = 5) -> Date {
        let calendar = Calendar.current
        let now = Date()
        guard let startOfMinute = calendar.dateInterval(of: .minute, for: now)?.start else { return now }
        let minute = calendar.component(.minute, from: startOfMinute)
        // Exactly on a step (18:10:00) stays; anything past it (18:10:30) goes to the next one.
        let isOnStep = minute % step == 0 && now == startOfMinute
        let add = isOnStep ? 0 : step - minute % step
        return calendar.date(byAdding: .minute, value: add, to: startOfMinute) ?? now
    }

    private var date: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// A one-off meeting set in the past would never remind.
    private var isInPast: Bool {
        recurrence == .once && date <= Date()
    }

    /// Weekly meetings pick a weekday instead of a date: the next such day from today.
    private var weekday: Binding<Int> {
        Binding(
            get: { Calendar.current.component(.weekday, from: day) },
            set: { weekday in
                let calendar = Calendar.current
                let today = calendar.startOfDay(for: Date())
                let offset = (weekday - calendar.component(.weekday, from: today) + 7) % 7
                day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            }
        )
    }

    private var meeting: Meeting? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !isInPast else { return nil }
        let meeting = Meeting(
            id: editing?.id ?? UUID(),
            title: trimmedTitle,
            link: link,
            date: date,
            recurrence: recurrence,
            leadMinutes: leadMinutes,
            alertStyle: alertStyle
        )
        // The link is optional, but if it's there it has to make sense.
        let hasLink = !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasLink && meeting.url == nil ? nil : meeting
    }

    var body: some View {
        // No title row: the fields need the height, and the button says "Добавить" / "Сохранить".
        NotchFormLayout(
            title: nil,
            submitTitle: editing == nil ? L("Добавить", "Add") : L("Сохранить", "Save"),
            hint: hint,
            canSubmit: meeting != nil,
            submit: submit,
            cancel: cancel
        ) {
            // A label column on the left, like macOS settings forms.
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    NotchFormLabel(L("Созвон", "Meeting"))
                    HStack(spacing: 6) {
                        NotchTextField(placeholder: L("Название", "Title"), text: $title)
                            .focused($focusedField, equals: .title)
                            .frame(width: 200)
                        NotchTextField(placeholder: L("Ссылка — необязательно", "Link (optional)"), text: $link)
                            .focused($focusedField, equals: .link)
                    }
                }
                GridRow {
                    NotchFormLabel(L("Повтор", "Repeat"))
                    HStack(spacing: 8) {
                        NotchSegmented(options: Meeting.Recurrence.allCases, title: \.title, selection: $recurrence)
                        Spacer(minLength: 0)
                        NotchFormLabel(L("Время", "Time"))
                        NotchTimeInput(hour: $hour, minute: $minute)
                    }
                }
                switch recurrence {
                case .once:
                    GridRow {
                        NotchFormLabel(L("Дата", "Date"))
                        NotchDayPicker(day: $day)
                    }
                case .weekly:
                    GridRow {
                        NotchFormLabel(L("День", "Day"))
                        NotchSegmented(
                            options: Self.weekdayOptions,
                            title: { Self.weekdaySymbols[$0 - 1] },
                            selection: weekday
                        )
                    }
                case .weekdays, .daily:
                    EmptyView()
                }
                GridRow {
                    NotchFormLabel(L("Напомнить", "Remind"))
                    HStack(spacing: 8) {
                        NotchSegmented(
                            options: Self.leadOptions,
                            title: { $0 == 0 ? L("в начале", "at start") : L("за \($0) мин", "\($0) min before") },
                            selection: $leadMinutes
                        )
                        NotchSegmented(options: Meeting.AlertStyle.allCases, title: \.title, selection: $alertStyle)
                    }
                }
            }
        }
        .onSubmit(submit)
        .onAppear {
            if editing == nil { prefillLinkFromClipboard() }
            // The panel becomes key in the same runloop turn; focus after that.
            DispatchQueue.main.async { focusedField = .title }
        }
    }

    private var hint: Text? {
        if !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, meeting?.url == nil, !title.isEmpty {
            return Text(L("Не похоже на ссылку", "Doesn’t look like a link")).foregroundStyle(.red)
        }
        if isInPast {
            return Text(L("Это время уже прошло", "This time has already passed")).foregroundStyle(.red)
        }
        if alertStyle == .alarm {
            return Text(L("Челка откроется со звуком, даже в «Не беспокоить»", "The notch will open with sound, even in Do Not Disturb")).foregroundStyle(.white.opacity(0.45))
        }
        return nil
    }

    private func submit() {
        if let meeting {
            save(meeting)
        } else if focusedField == .title {
            focusedField = .link
        }
    }

    /// A copied web link is most likely the meeting's link.
    private func prefillLinkFromClipboard() {
        guard let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              copied.count < 2000,
              copied.hasPrefix("http://") || copied.hasPrefix("https://")
        else { return }
        link = copied
    }
}

/// Shown instead of the tabs while a meeting alarm rings.
struct MeetingAlarmView: View {
    let alarm: MeetingStore.Alarm
    let join: () -> Void
    let dismiss: () -> Void

    @State private var pulse = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            // Centered in the notch, like an incoming call on the iPhone's Dynamic Island.
            VStack(spacing: 6) {
                Image(systemName: "alarm.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                    .scaleEffect(pulse ? 1.08 : 0.94)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .padding(.bottom, 2)
                Text(alarm.meeting.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(status(now: context.date))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 10) {
                    NotchFormButton(title: L("Закрыть", "Close"), action: dismiss)
                    if alarm.meeting.url != nil {
                        NotchFormButton(title: L("Подключиться", "Join"), isPrimary: true, tint: .green, action: join)
                    }
                }
                .padding(.top, 8)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func status(now: Date) -> String {
        let time = alarm.start.formatted(.dateTime.hour().minute())
        let minutes = Int(alarm.start.timeIntervalSince(now) / 60)
        if minutes > 0 { return L("Через \(minutes) мин · в \(time)", "In \(minutes) min · at \(time)") }
        if minutes == 0 { return L("Начинается сейчас · \(time)", "Starting now · \(time)") }
        return L("Начался \(-minutes) мин назад · в \(time)", "Started \(-minutes) min ago · at \(time)")
    }
}
