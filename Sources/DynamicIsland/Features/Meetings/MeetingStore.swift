import AppKit
import Combine
import UserNotifications

struct Meeting: Codable, Identifiable, Equatable {
    enum Recurrence: String, Codable, CaseIterable, Identifiable {
        case once, weekdays, daily, weekly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .once: L("Один раз", "Once")
            case .weekdays: L("По будням", "Weekdays")
            case .daily: L("Каждый день", "Daily")
            case .weekly: L("Раз в неделю", "Weekly")
            }
        }
    }

    enum AlertStyle: String, Codable, CaseIterable, Identifiable {
        /// A regular macOS notification (silenced by Focus / Do Not Disturb).
        case notification
        /// The notch opens by itself and plays a sound until dismissed.
        case alarm

        var id: String { rawValue }

        var title: String {
            switch self {
            case .notification: L("Уведомление", "Notification")
            case .alarm: L("Будильник", "Alarm")
            }
        }
    }

    /// Where a meeting from the Calendar came from; nil for ones added in the notch.
    struct CalendarEvent: Codable, Equatable {
        /// The event and its start, e.g. for one occurrence of a repeating event.
        let key: String
        let end: Date
        let calendarTitle: String
        let colorHex: String?
    }

    var id = UUID()
    var title: String
    var link: String
    /// The first occurrence; for repeating meetings its time of day (and weekday, if weekly) is used.
    var date: Date
    var recurrence: Recurrence
    /// How many minutes before the start to remind.
    var leadMinutes: Int
    var alertStyle: AlertStyle
    var calendarEvent: CalendarEvent? = nil

    /// Web links get https:// added if missing; app links like zoommtg:// are kept as is.
    var url: URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              !["file", "javascript", "data"].contains(scheme)
        else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = url.host, host.contains(".") else { return nil }
        }
        return url
    }

    /// The first start strictly after `reference`, or nil for a one-off meeting that has passed.
    func nextOccurrence(after reference: Date, calendar: Calendar = .current) -> Date? {
        if recurrence == .once {
            return date > reference ? date : nil
        }
        // Repeating meetings don't start before their first date.
        let start = max(reference, date.addingTimeInterval(-1))
        let time = calendar.dateComponents([.hour, .minute], from: date)
        return weekdays(calendar: calendar).compactMap { weekday -> Date? in
            var components = DateComponents(hour: time.hour, minute: time.minute)
            components.weekday = weekday
            return calendar.nextDate(after: start, matching: components, matchingPolicy: .nextTime)
        }.min()
    }

    /// Calendar weekdays (1 = Sunday) the meeting repeats on; [nil] means every day.
    func weekdays(calendar: Calendar = .current) -> [Int?] {
        switch recurrence {
        case .once, .daily: [nil]
        case .weekdays: [2, 3, 4, 5, 6]
        case .weekly: [calendar.component(.weekday, from: date)]
        }
    }
}

/// Stores meetings, schedules their notifications and rings alarms, for the ones added in the
/// notch and the ones from the Calendar alike.
@MainActor
final class MeetingStore: ObservableObject {
    struct Alarm: Equatable {
        let meeting: Meeting
        let start: Date
    }

    @Published var meetings: [Meeting] {
        didSet {
            save()
            scheduleNotifications()
        }
    }
    /// From the Calendar; not saved, read again from it.
    @Published private(set) var calendarMeetings: [Meeting] = [] {
        didSet { scheduleNotifications() }
    }
    let calendar = CalendarMeetings()
    /// The alarm currently shown in the notch.
    @Published private(set) var activeAlarm: Alarm?
    @Published private(set) var notificationsDenied = false

    // Read by the notification delegate, which isn't on the main actor.
    nonisolated static let notificationCategory = "meeting"
    nonisolated static let joinAction = "join"

    private static let defaultsKey = "meetings"
    /// A Mac that wakes up (or an app that launches) shortly after a start still rings for it.
    private static let lateGrace: TimeInterval = 10 * 60

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// "meetingID@start" → start, for occurrences that have already rung.
    private var ringedAlarms = UserDefaults.standard.dictionary(forKey: ringedAlarmsKey) as? [String: Double] ?? [:]
    private static let ringedAlarmsKey = "ringedAlarms"
    private var sound: NSSound?
    private var soundStopTask: Task<Void, Never>?
    private var scheduleGeneration = 0
    private var calendarSubscription: Any?

    /// Added in the notch and from the Calendar.
    var allMeetings: [Meeting] { meetings + calendarMeetings }

    init() {
        let data = UserDefaults.standard.data(forKey: Self.defaultsKey)
        meetings = data.flatMap { try? JSONDecoder().decode([Meeting].self, from: $0) } ?? []
        // Ones that finished while the app wasn't running.
        removeFinishedMeetings()

        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAlarms() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAlarms() }
        }
        scheduleNotifications()
        calendarSubscription = calendar.$meetings.sink { [weak self] meetings in
            guard let self, meetings != calendarMeetings else { return }
            calendarMeetings = meetings
            checkAlarms()
        }
    }

    /// Meetings with their next start, soonest first; ones that just started stay on top for a while.
    func upcoming(now: Date = Date()) -> [(meeting: Meeting, start: Date?)] {
        let reference = now.addingTimeInterval(-Self.lateGrace)
        return allMeetings
            .map { meeting in
                // A calendar event stays until it ends, not just for the first minutes.
                if let end = meeting.calendarEvent?.end, end > now { return (meeting, meeting.date) }
                return (meeting, meeting.nextOccurrence(after: reference))
            }
            .sorted { lhs, rhs in
                switch (lhs.1, rhs.1) {
                case let (l?, r?): l < r
                case (nil, _?): false
                case (_?, nil): true
                case (nil, nil): lhs.0.title < rhs.0.title
                }
            }
    }

    func add(_ meeting: Meeting) {
        meetings.append(meeting)
    }

    func update(_ meeting: Meeting) {
        if meeting.calendarEvent != nil {
            calendar.setAlertStyle(meeting.alertStyle, for: meeting)
            return
        }
        guard let index = meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
        meetings[index] = meeting
    }

    /// A calendar event is only hidden here; it stays in the Calendar.
    func remove(_ meeting: Meeting) {
        if meeting.calendarEvent != nil {
            calendar.hide(meeting)
        } else {
            meetings.removeAll { $0.id == meeting.id }
        }
        if activeAlarm?.meeting.id == meeting.id { dismissAlarm() }
    }

    func join(_ meeting: Meeting) {
        if let url = meeting.url { NSWorkspace.shared.open(url) }
        if activeAlarm?.meeting.id == meeting.id { dismissAlarm() }
    }

    func dismissAlarm() {
        soundStopTask?.cancel()
        sound?.stop()
        sound = nil
        activeAlarm = nil
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Alarms

    /// One-off meetings go away on their own 10 minutes after they start.
    private func removeFinishedMeetings() {
        let cutoff = Date().addingTimeInterval(-Self.lateGrace)
        let finished = meetings.filter { $0.recurrence == .once && $0.date < cutoff }
        guard !finished.isEmpty else { return }
        meetings.removeAll { finished.contains($0) }
    }

    private func checkAlarms() {
        removeFinishedMeetings()
        let now = Date()
        if let alarm = activeAlarm, now > alarm.start.addingTimeInterval(Self.lateGrace) {
            dismissAlarm()
        }
        guard activeAlarm == nil else { return }

        for meeting in allMeetings where meeting.alertStyle == .alarm {
            guard let start = meeting.nextOccurrence(after: now.addingTimeInterval(-Self.lateGrace)) else { continue }
            let ringAt = start.addingTimeInterval(-Double(meeting.leadMinutes * 60))
            let key = "\(meeting.id)@\(Int(start.timeIntervalSince1970))"
            guard now >= ringAt, ringedAlarms[key] == nil else { continue }

            markRinged(key, start: start)
            ring(Alarm(meeting: meeting, start: start))
            return
        }
    }

    /// Remembered on disk: otherwise a relaunch inside the reminder window (up to 15 minutes
    /// before the start) would ring the same meeting again.
    private func markRinged(_ key: String, start: Date) {
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
        ringedAlarms = ringedAlarms.filter { $0.value > dayAgo }
        ringedAlarms[key] = start.timeIntervalSince1970
        UserDefaults.standard.set(ringedAlarms, forKey: Self.ringedAlarmsKey)
    }

    private func ring(_ alarm: Alarm) {
        activeAlarm = alarm
        // One sound for all alarms, chosen in Settings.
        let sound = AlarmSound.sound()
        sound?.loops = true
        sound?.play()
        self.sound = sound
        // Keep the notch open, but don't beep forever if the Mac is unattended.
        soundStopTask = Task {
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled else { return }
            self.sound?.stop()
        }
    }

    // MARK: - Notifications

    /// Rebuilds all pending notifications from the current list.
    private func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        scheduleGeneration += 1
        let generation = scheduleGeneration
        let meetings = allMeetings.filter { $0.alertStyle == .notification }
        guard !meetings.isEmpty else { return }

        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            notificationsDenied = !granted
            guard granted else { return }
            for meeting in meetings {
                for (index, trigger) in Self.triggers(for: meeting).enumerated() {
                    // A newer edit rebuilt the list meanwhile; don't re-add stale requests.
                    guard generation == scheduleGeneration else { return }
                    let request = UNNotificationRequest(
                        identifier: "\(meeting.id)-\(index)",
                        content: Self.content(for: meeting),
                        trigger: trigger
                    )
                    try? await center.add(request)
                    // A rebuild that started while this was being added has already cleared the
                    // list; this request would outlive it, for a meeting that may be gone.
                    if generation != scheduleGeneration {
                        center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                        return
                    }
                }
            }
        }
    }

    private static func content(for meeting: Meeting) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = meeting.title
        content.body = meeting.leadMinutes == 0 ? L("Начинается сейчас", "Starting now") : L("Начнётся через \(meeting.leadMinutes) мин", "Starts in \(meeting.leadMinutes) min")
        content.sound = .default
        content.categoryIdentifier = notificationCategory
        content.userInfo = ["link": meeting.url?.absoluteString ?? ""]
        return content
    }

    private static func triggers(for meeting: Meeting, calendar: Calendar = .current) -> [UNCalendarNotificationTrigger] {
        let lead = meeting.leadMinutes
        if meeting.recurrence == .once {
            let fireAt = meeting.date.addingTimeInterval(-Double(lead * 60))
            guard fireAt > Date() else { return [] }
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            return [UNCalendarNotificationTrigger(dateMatching: components, repeats: false)]
        }

        let time = calendar.dateComponents([.hour, .minute], from: meeting.date)
        let hour = time.hour ?? 0, minute = time.minute ?? 0
        return meeting.weekdays(calendar: calendar).map { weekday in
            guard let weekday else {
                // Every day: just shift the time of day.
                let total = ((hour * 60 + minute - lead) % 1440 + 1440) % 1440
                return UNCalendarNotificationTrigger(
                    dateMatching: DateComponents(hour: total / 60, minute: total % 60), repeats: true
                )
            }
            // Shifting by the lead time can cross midnight, so work in minutes of the week.
            let week = 7 * 1440
            let total = (((weekday - 1) * 1440 + hour * 60 + minute - lead) % week + week) % week
            var components = DateComponents(hour: total % 1440 / 60, minute: total % 60)
            components.weekday = total / 1440 + 1
            return UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(meetings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
