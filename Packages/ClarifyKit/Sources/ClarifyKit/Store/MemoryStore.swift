import Foundation

/// In-memory Store for tests and the eval runner. Mirrors EventKit semantics:
/// identifiers are stable, lists are created on demand, completion is a flag.
public final class MemoryStore: Store, @unchecked Sendable {
    private let lock = NSLock()
    private var lists: [String]
    private var items: [String: ReminderItem] = [:]
    private var order: [String] = []
    public private(set) var events: [NewEvent] = []
    private let inbox: String
    private var nextID = 1

    public init(inbox: String = "Reminders", lists: [String] = []) {
        self.inbox = inbox
        self.lists = Array(Set([inbox] + lists)).sorted()
    }

    public func listNames() async throws -> [String] { lock.withLock { lists } }

    public func ensureLists(_ names: [String]) async throws {
        lock.withLock { for n in names where !lists.contains(n) { lists.append(n) } }
    }

    public func inboxListName() async throws -> String { inbox }

    public func reminders(in list: String, includeCompleted: Bool) async throws -> [ReminderItem] {
        lock.withLock { order.compactMap { items[$0] }.filter { $0.list == list && (includeCompleted || !$0.isCompleted) } }
    }

    public func reminder(id: String) async throws -> ReminderItem? { lock.withLock { items[id] } }

    public func create(_ new: NewReminder) async throws -> ReminderItem {
        lock.withLock {
            if !lists.contains(new.list) { lists.append(new.list) }
            let item = ReminderItem(id: "mem-\(nextID)", title: new.title, notes: new.notes, list: new.list,
                                    startDate: new.startDate, dueDate: new.dueDate, creationDate: Date())
            nextID += 1
            items[item.id] = item
            order.append(item.id)
            return item
        }
    }

    public func save(_ item: ReminderItem) async throws {
        lock.withLock {
            precondition(items[item.id] != nil, "save of unknown reminder \(item.id)")
            if !lists.contains(item.list) { lists.append(item.list) }
            items[item.id] = item
        }
    }

    public func createEvent(_ event: NewEvent) async throws -> String {
        lock.withLock { events.append(event); return "event-\(events.count)" }
    }

    public func events(on day: Date) async throws -> [String] {
        let cal = Calendar.current
        return lock.withLock { events.filter { cal.isDate($0.start, inSameDayAs: day) } }
            .map { $0.allDay ? $0.title : "\(Self.time.string(from: $0.start)) \($0.title)" }
    }
    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    /// Test helper: all reminders across lists in creation order.
    public func all() -> [ReminderItem] { lock.withLock { order.compactMap { items[$0] } } }
}
