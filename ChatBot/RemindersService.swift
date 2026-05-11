import EventKit
import Foundation
import AppKit

@MainActor
final class RemindersService {
    let store = EKEventStore()

    var authStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    var calendarAuthStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    // True when the app can read/write reminders — accepts both fullAccess
    // and writeOnly (writeOnly = user granted access via the old macOS ≤ 13
    // API; we can still read and write, so treat it as sufficient).
    var isAuthorized: Bool {
        let s = authStatus
        if #unavailable(macOS 14.0) {
            return s == .authorized
        }
        return s == .fullAccess || s == .writeOnly
    }

    var isCalendarAuthorized: Bool {
        let s = calendarAuthStatus
        if #unavailable(macOS 14.0) {
            return s == .authorized
        }
        return s == .fullAccess || s == .writeOnly
    }

    // True only when the OS hasn't asked yet — this is the only case where
    // we should present a system permission dialog.
    var needsRemindersRequest: Bool { authStatus == .notDetermined }
    var needsCalendarRequest:  Bool { calendarAuthStatus == .notDetermined }

    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    func requestCalendarAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    // MARK: - Lists

    func getLists() -> [EKCalendar] {
        store.calendars(for: .reminder)
    }

    func getReminder(id: String) -> EKReminder? {
        store.calendarItem(withIdentifier: id) as? EKReminder
    }

    func getEventCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
    }

    func getEvent(id: String) -> EKEvent? {
        store.event(withIdentifier: id)
    }

    func getEvents(calendarName: String? = nil, startDate: Date, endDate: Date) -> [EKEvent] {
        let calendars: [EKCalendar]?
        if let name = calendarName, !name.isEmpty {
            calendars = getEventCalendars().filter { $0.title.lowercased().contains(name.lowercased()) }
        } else {
            calendars = nil
        }

        let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: calendars)
        return store.events(matching: predicate)
    }

    // MARK: - Read

    func getReminders(listName: String? = nil, includeCompleted: Bool = false) async -> [EKReminder] {
        let cals: [EKCalendar]?
        if let n = listName {
            cals = getLists().filter { $0.title.lowercased().contains(n.lowercased()) }
        } else {
            cals = nil
        }
        let pred = store.predicateForReminders(in: cals)
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: pred) { reminders in
                let result = (reminders ?? []).filter { includeCompleted || !$0.isCompleted }
                cont.resume(returning: result)
            }
        }
    }

    // MARK: - Write

    @discardableResult
    func createReminder(title: String, dueDate: Date? = nil, notes: String? = nil, listName: String? = nil) throws -> String {
        let r = EKReminder(eventStore: store)
        r.title = title
        r.notes = notes
        r.calendar = listName.flatMap { n in getLists().first { $0.title.lowercased() == n.lowercased() } }
                     ?? store.defaultCalendarForNewReminders()
        if let d = dueDate {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        }
        try store.save(r, commit: true)
        return r.calendarItemIdentifier
    }

    func completeReminder(id: String) throws {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RError.notFound
        }
        r.isCompleted = true
        try store.save(r, commit: true)
    }

    func deleteReminder(id: String) throws {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RError.notFound
        }
        try store.remove(r, commit: true)
    }

    func updateReminder(id: String, title: String? = nil, dueDate: Date? = nil, notes: String? = nil, clearDueDate: Bool = false) throws {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw RError.notFound
        }
        if let t = title { r.title = t }
        if let n = notes { r.notes = n }
        if clearDueDate { r.dueDateComponents = nil }
        if let d = dueDate {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        }
        try store.save(r, commit: true)
    }

    @discardableResult
    func createEvent(title: String,
                     startDate: Date,
                     endDate: Date,
                     notes: String? = nil,
                     location: String? = nil,
                     calendarName: String? = nil,
                     isAllDay: Bool = false,
                     weeklyRecurrenceEndDate: Date? = nil) throws -> String {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.notes = notes
        event.location = location
        event.isAllDay = isAllDay
        event.calendar = calendarName.flatMap { name in
            getEventCalendars().first { $0.title.lowercased() == name.lowercased() }
        } ?? store.defaultCalendarForNewEvents

        if let endDate = weeklyRecurrenceEndDate {
            event.recurrenceRules = [
                EKRecurrenceRule(
                    recurrenceWith: .weekly,
                    interval: 1,
                    end: EKRecurrenceEnd(end: endDate)
                )
            ]
        }

        try store.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier else { throw APIError.invalidResponse }
        return id
    }

    func updateEvent(id: String,
                     title: String? = nil,
                     startDate: Date? = nil,
                     endDate: Date? = nil,
                     notes: String? = nil,
                     location: String? = nil,
                     clearNotes: Bool = false,
                     clearLocation: Bool = false) throws {
        guard let event = getEvent(id: id) else { throw RError.notFound }
        if let title { event.title = title }
        if let startDate { event.startDate = startDate }
        if let endDate { event.endDate = endDate }
        if clearNotes { event.notes = nil }
        else if let notes { event.notes = notes }
        if clearLocation { event.location = nil }
        else if let location { event.location = location }
        try store.save(event, span: .thisEvent, commit: true)
    }

    func deleteEvent(id: String) throws {
        guard let event = getEvent(id: id) else { throw RError.notFound }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    // MARK: - Format helper

    static func format(_ r: EKReminder) -> String {
        var parts: [String] = ["• \(r.title ?? "(无标题)")"]
        parts.append("  清单: \(r.calendar.title)")
        if r.isCompleted { parts.append("  状态: 已完成") }
        if let comps = r.dueDateComponents, let date = Calendar.current.date(from: comps) {
            let fmt = DateFormatter()
            fmt.dateStyle = .medium; fmt.timeStyle = .short
            parts.append("  截止: \(fmt.string(from: date))")
        }
        if let notes = r.notes, !notes.isEmpty { parts.append("  备注: \(notes)") }
        parts.append("  ID: \(r.calendarItemIdentifier)")
        return parts.joined(separator: "\n")
    }

    static func snapshot(_ r: EKReminder) -> ScheduleReminderItem {
        var dueDate: Date?
        if let comps = r.dueDateComponents {
            dueDate = Calendar.current.date(from: comps)
        }

        return ScheduleReminderItem(
            id: r.calendarItemIdentifier,
            title: r.title ?? "(无标题)",
            listName: r.calendar.title,
            dueDate: dueDate,
            notes: r.notes,
            isCompleted: r.isCompleted
        )
    }

    static func snapshot(_ e: EKEvent) -> ScheduleCalendarEventItem {
        let cleanNotes = cleanedCourseNotes(e.notes)
        return ScheduleCalendarEventItem(
            id: e.eventIdentifier ?? UUID().uuidString,
            title: e.title ?? "(无标题)",
            calendarName: e.calendar.title,
            startDate: e.startDate,
            endDate: e.endDate,
            location: e.location,
            notes: cleanNotes?.isEmpty == true ? nil : cleanNotes,
            isAllDay: e.isAllDay
        )
    }

    private static func cleanedCourseNotes(_ notes: String?) -> String? {
        notes?
            .replacingOccurrences(of: "\n\n[ChatBotCourse]", with: "")
            .replacingOccurrences(of: "[ChatBotCourse]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Native Reminders UI

    func openReminder(id: String) {
        let script = """
        tell application "Reminders"
            activate
            show (first reminder whose id is "\(appleScriptEscaped(id))")
        end tell
        """
        runAppleScriptOrOpenApp(script)
    }

    func openList(id: String) {
        let script = """
        tell application "Reminders"
            activate
            show (first list whose id is "\(appleScriptEscaped(id))")
        end tell
        """
        runAppleScriptOrOpenApp(script)
    }

    func openApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    private func runAppleScriptOrOpenApp(_ source: String) {
        guard let script = NSAppleScript(source: source) else {
            openApp()
            return
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if error != nil {
            openApp()
        }
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

enum RError: LocalizedError {
    case notFound
    var errorDescription: String? { "找不到该提醒事项" }
}
