import AppKit
import CryptoKit
import EventKit

/// Meetings from the macOS Calendar (iCloud, Google, Exchange accounts added in System Settings):
/// the next week's events, with the video call link found in them. Read only; nothing leaves the Mac.
@MainActor
final class CalendarMeetings: ObservableObject {
    enum Access {
        case notDetermined, granted, denied
    }

    struct CalendarInfo: Identifiable, Equatable {
        let id: String
        let title: String
        let account: String
        let color: NSColor
    }

    @Published private(set) var access: Access
    /// Converted to meetings, soonest first; empty while off.
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var calendars: [CalendarInfo] = []

    @Published var isEnabled: Bool {
        didSet { settingChanged(Self.enabledKey, isEnabled) }
    }
    /// Only events with a video call link, for calendars full of lunches and focus blocks.
    @Published var onlyWithLinks: Bool {
        didSet { settingChanged(Self.onlyWithLinksKey, onlyWithLinks) }
    }
    @Published var leadMinutes: Int {
        didSet { settingChanged(Self.leadMinutesKey, leadMinutes) }
    }
    @Published var alertStyle: Meeting.AlertStyle {
        didSet { settingChanged(Self.alertStyleKey, alertStyle.rawValue) }
    }
    /// Calendars turned off in Settings; new ones are on.
    @Published private(set) var excludedCalendars: Set<String>

    private let store = EKEventStore()
    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Per event: a different reminder than the default, or hidden from the list.
    private var alertOverrides: [String: String]
    @Published private(set) var hiddenEvents: [String: Double]
    /// Just hidden in the notch, for a moment: it can be brought back.
    @Published private(set) var lastHidden: Meeting?
    private var lastHiddenTask: Task<Void, Never>?

    private static let enabledKey = "calendarMeetingsEnabled"
    private static let onlyWithLinksKey = "calendarOnlyWithLinks"
    private static let leadMinutesKey = "calendarLeadMinutes"
    private static let alertStyleKey = "calendarAlertStyle"
    private static let excludedKey = "calendarExcluded"
    private static let overridesKey = "calendarAlertOverrides"
    private static let hiddenKey = "calendarHiddenEvents"
    private static let lookAhead: TimeInterval = 7 * 24 * 60 * 60

    init() {
        let defaults = UserDefaults.standard
        access = Self.currentAccess()
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        onlyWithLinks = defaults.object(forKey: Self.onlyWithLinksKey) as? Bool ?? false
        leadMinutes = defaults.object(forKey: Self.leadMinutesKey) as? Int ?? 5
        alertStyle = defaults.string(forKey: Self.alertStyleKey).flatMap(Meeting.AlertStyle.init) ?? .notification
        excludedCalendars = Set(defaults.stringArray(forKey: Self.excludedKey) ?? [])
        alertOverrides = defaults.dictionary(forKey: Self.overridesKey) as? [String: String] ?? [:]
        hiddenEvents = defaults.dictionary(forKey: Self.hiddenKey) as? [String: Double] ?? [:]

        observers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        // Events move into and out of the week-long window as time passes.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Asks for access the first time, then turns the calendar on.
    func connect() {
        guard access != .granted else {
            isEnabled = true
            return
        }
        guard access == .notDetermined else {
            openPrivacySettings()
            return
        }
        Task {
            // The system's prompt belongs to an active app.
            NSApp.activate()
            _ = try? await store.requestFullAccessToEvents()
            access = Self.currentAccess()
            if access == .granted {
                // A store made before access was granted doesn't see the calendars yet.
                store.reset()
                isEnabled = true
            }
            refresh()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func isIncluded(_ calendar: CalendarInfo) -> Bool {
        !excludedCalendars.contains(calendar.id)
    }

    func setIncluded(_ calendar: CalendarInfo, _ included: Bool) {
        if included { excludedCalendars.remove(calendar.id) } else { excludedCalendars.insert(calendar.id) }
        UserDefaults.standard.set(Array(excludedCalendars), forKey: Self.excludedKey)
        refresh()
    }

    /// This one event reminds differently from the default.
    func setAlertStyle(_ style: Meeting.AlertStyle, for meeting: Meeting) {
        guard let key = meeting.calendarEvent?.key else { return }
        alertOverrides[key] = style == alertStyle ? nil : style.rawValue
        UserDefaults.standard.set(alertOverrides, forKey: Self.overridesKey)
        refresh()
    }

    /// Takes one event off the list, e.g. a meeting you won't go to.
    func hide(_ meeting: Meeting) {
        guard let event = meeting.calendarEvent else { return }
        hiddenEvents[event.key] = event.end.timeIntervalSince1970
        // Forget events that are long over.
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970
        hiddenEvents = hiddenEvents.filter { $0.value > dayAgo }
        UserDefaults.standard.set(hiddenEvents, forKey: Self.hiddenKey)
        refresh()

        lastHidden = meeting
        lastHiddenTask?.cancel()
        lastHiddenTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            lastHidden = nil
        }
    }

    /// Brings back the event hidden last.
    func undoHide() {
        guard let key = lastHidden?.calendarEvent?.key else { return }
        lastHiddenTask?.cancel()
        lastHidden = nil
        hiddenEvents[key] = nil
        UserDefaults.standard.set(hiddenEvents, forKey: Self.hiddenKey)
        refresh()
    }

    /// Hidden events that haven't ended yet.
    var hiddenCount: Int {
        let now = Date().timeIntervalSince1970
        return hiddenEvents.values.filter { $0 > now }.count
    }

    func showHiddenEvents() {
        hiddenEvents = [:]
        UserDefaults.standard.removeObject(forKey: Self.hiddenKey)
        refresh()
    }

    func refresh() {
        access = Self.currentAccess()
        guard access == .granted else {
            if !meetings.isEmpty { meetings = [] }
            if !calendars.isEmpty { calendars = [] }
            return
        }

        let eventCalendars = store.calendars(for: .event)
        let infos = eventCalendars
            .map { CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "", color: $0.color) }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        if infos != calendars { calendars = infos }

        let included = eventCalendars.filter { !excludedCalendars.contains($0.calendarIdentifier) }
        guard isEnabled, !included.isEmpty else {
            if !meetings.isEmpty { meetings = [] }
            return
        }

        let now = Date()
        // From half a day back, for events that are still going on.
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-12 * 60 * 60), end: now.addingTimeInterval(Self.lookAhead), calendars: included)
        let found = store.events(matching: predicate)
            .filter { event in
                !event.isAllDay && event.status != .canceled && event.endDate > now
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .compactMap(meeting(from:))
            .sorted { $0.date < $1.date }
        if found != meetings { meetings = found }
    }

    // MARK: - Private

    private func meeting(from event: EKEvent) -> Meeting? {
        let link = MeetingLinkDetector.link(in: event)
        if onlyWithLinks && link == nil { return nil }
        let key = "\(event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier)@\(Int(event.startDate.timeIntervalSince1970))"
        guard hiddenEvents[key] == nil else { return nil }

        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Meeting(
            id: Self.stableID(for: key),
            title: title.isEmpty ? L("Без названия", "Untitled") : title,
            link: link?.absoluteString ?? "",
            date: event.startDate,
            recurrence: .once,
            leadMinutes: leadMinutes,
            alertStyle: alertOverrides[key].flatMap(Meeting.AlertStyle.init) ?? alertStyle,
            calendarEvent: Meeting.CalendarEvent(
                key: key,
                end: event.endDate,
                calendarTitle: event.calendar?.title ?? "",
                colorHex: event.calendar.flatMap { PickedColor($0.color)?.hex }
            )
        )
    }

    /// The same event gets the same id on every refresh, so alarms and notifications keep track of it.
    private static func stableID(for key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private func settingChanged(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        refresh()
    }
}

/// Finds the video call link in an event: its URL field, location or notes.
enum MeetingLinkDetector {
    /// Host, and a path part the join link has (other pages on these sites aren't meetings).
    private static let services: [(host: String, path: String?)] = [
        ("zoom.us", "/j/"), ("zoom.us", "/my/"), ("zoom.us", "/w/"), ("zoom.com", "/j/"),
        ("meet.google.com", nil),
        ("teams.microsoft.com", "meetup-join"), ("teams.microsoft.com", "/meet/"), ("teams.live.com", "/meet/"),
        ("webex.com", "/meet/"), ("webex.com", "/join/"), ("webex.com", "j.php"),
        ("telemost.yandex.ru", "/j/"), ("telemost.360.yandex.ru", "/j/"),
        ("meet.jit.si", nil), ("whereby.com", nil), ("around.co", nil),
        ("app.slack.com", "/huddle/"), ("discord.gg", nil), ("discord.com", "/channels/"),
        ("meet.goto.com", nil), ("gotomeeting.com", "/join/"), ("chime.aws", nil),
        ("vk.com", "/call/join/"), ("salutejazz.ru", nil), ("jazz.sber.ru", nil), ("ktalk.ru", nil),
    ]
    /// Links that open a meeting app directly.
    private static let appSchemes: Set<String> = ["zoommtg", "zoomus", "msteams", "webex", "facetime"]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func link(in event: EKEvent) -> URL? {
        if let url = event.url, isMeeting(url) { return url }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let url = firstMeeting(in: text) { return url }
        }
        return nil
    }

    static func firstMeeting(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        guard let url = detector?.matches(in: text, range: range).compactMap(\.url).first(where: isMeeting) else { return nil }
        // "meet.google.com/abc" in text is detected as http://; every service here is on https.
        guard url.scheme == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    static func isMeeting(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if appSchemes.contains(scheme) { return true }
        guard scheme == "https" || scheme == "http", let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased() + (url.query.map { "?" + $0 } ?? "")
        return services.contains { service in
            (host == service.host || host.hasSuffix("." + service.host))
                && (service.path.map { path.contains($0) } ?? (url.path.count > 1))
        }
    }
}

