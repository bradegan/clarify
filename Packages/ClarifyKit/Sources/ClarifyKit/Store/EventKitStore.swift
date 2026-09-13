import Foundation
import EventKit

/// The real Store over EventKit. All calls are funneled through one actor so the
/// non-Sendable EKEventStore is only ever touched from one place.
public actor EventKitStore: Store {
    private let store = EKEventStore()
    private var listCache: [String: EKCalendar] = [:]

    public init() {}

    public enum AccessError: Error, LocalizedError {
        case remindersDenied, calendarDenied
        public var errorDescription: String? {
            switch self {
            case .remindersDenied: return "Reminders access was not granted"
            case .calendarDenied: return "Calendar access was not granted"
            }
        }
    }

    public private(set) var calendarGranted = false

    /// Reminders access is required. Calendar access is requested but optional:
    /// without it the daemon still runs and calendar items report the missing grant.
    public func requestAccess() async throws {
        guard try await store.requestFullAccessToReminders() else { throw AccessError.remindersDenied }
        calendarGranted = (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The EventKit change notification the daemon subscribes to, posted for every store.
    nonisolated public static let changeNotification: Notification.Name = .EKEventStoreChanged

    // MARK: lists

    private func reminderLists() -> [EKCalendar] { store.calendars(for: .reminder) }

    private func list(named name: String) -> EKCalendar? {
        if let c = listCache[name] { return c }
        let found = reminderLists().first { $0.title == name }
        if let found { listCache[name] = found }
        return found
    }

    public func listNames() async throws -> [String] { reminderLists().map(\.title) }

    public func inboxListName() async throws -> String {
        guard let d = store.defaultCalendarForNewReminders() else { throw AccessError.remindersDenied }
        return d.title
    }

    public func ensureLists(_ names: [String]) async throws {
        let existing = Set(reminderLists().map(\.title))
        let missing = names.filter { !existing.contains($0) }
        guard !missing.isEmpty else { return }
        let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .calDAV }
            ?? store.sources.first { $0.sourceType == .local }
        guard let source else { throw AccessError.remindersDenied }
        for name in missing {
            let cal = EKCalendar(for: .reminder, eventStore: store)
            cal.title = name
            cal.source = source
            try store.saveCalendar(cal, commit: false)
            listCache[name] = cal
        }
        try store.commit()
    }

    // MARK: reminders

    public func reminders(in listName: String, includeCompleted: Bool) async throws -> [ReminderItem] {
        guard let cal = list(named: listName) else { return [] }
        let predicate = store.predicateForReminders(in: [cal])
        let found: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { cont.resume(returning: $0 ?? []) }
        }
        return found.filter { includeCompleted || !$0.isCompleted }
            .sorted { ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast) }
            .map(ReminderItem.init)
    }

    public func reminder(id: String) async throws -> ReminderItem? {
        (store.calendarItem(withIdentifier: id) as? EKReminder).map(ReminderItem.init)
    }

    public func create(_ new: NewReminder) async throws -> ReminderItem {
        try await ensureLists([new.list])
        guard let cal = list(named: new.list) else { throw AccessError.remindersDenied }
        let r = EKReminder(eventStore: store)
        r.title = new.title
        r.notes = new.notes
        r.calendar = cal
        r.startDateComponents = new.startDate
        r.dueDateComponents = new.dueDate
        try store.save(r, commit: true)
        return ReminderItem(r)
    }

    public func save(_ item: ReminderItem) async throws {
        guard let r = store.calendarItem(withIdentifier: item.id) as? EKReminder else {
            throw BridgeError.notFound("Reminder \(item.id) no longer exists")
        }
        try await ensureLists([item.list])
        guard let cal = list(named: item.list) else { throw AccessError.remindersDenied }
        r.title = item.title
        r.notes = item.notes
        r.calendar = cal
        r.startDateComponents = item.startDate
        r.dueDateComponents = item.dueDate
        r.priority = item.priority
        if item.isCompleted != r.isCompleted { r.isCompleted = item.isCompleted }
        try store.save(r, commit: true)
    }

    // MARK: calendar

    public func createEvent(_ event: NewEvent) async throws -> String {
        guard calendarGranted else { throw AccessError.calendarDenied }
        let e = EKEvent(eventStore: store)
        e.title = event.title
        e.startDate = event.start
        e.endDate = event.allDay ? event.start : event.end
        e.isAllDay = event.allDay
        e.notes = event.notes
        e.calendar = store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent, commit: true)
        return e.eventIdentifier ?? ""
    }

    public func events(on day: Date) async throws -> [String] {
        guard calendarGranted else { return [] }
        let cal = Calendar.current
        let start = cal.startOfDay(for: day)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return [] }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }
            .map { $0.isAllDay ? ($0.title ?? "") : "\(f.string(from: $0.startDate)) \($0.title ?? "")" }
    }
}

extension ReminderItem {
    init(_ r: EKReminder) {
        self.init(id: r.calendarItemIdentifier, title: r.title ?? "", notes: r.notes, list: r.calendar?.title ?? "",
                  startDate: r.startDateComponents, dueDate: r.dueDateComponents, priority: r.priority,
                  isCompleted: r.isCompleted, creationDate: r.creationDate)
    }
}
