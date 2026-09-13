import Foundation

/// The GTD buckets Clarify creates as Reminders lists. The inbox is whatever list
/// Reminders reports as the default for new reminders, so it is not in this list.
public enum Bucket: String, CaseIterable, Sendable {
    case nextActions = "Next Actions"
    case projects = "Projects"
    case waitingFor = "Waiting For"
    case someday = "Someday/Maybe"
    case reference = "Reference"
    case approve = "Approve"
    case weeklyReview = "Weekly Review"
    case today = "Today"
    case trash = "Trash"
}

public struct ReminderItem: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var notes: String?
    public var list: String
    public var startDate: DateComponents?
    public var dueDate: DateComponents?
    public var priority: Int
    public var isCompleted: Bool
    public var creationDate: Date?

    public init(id: String, title: String, notes: String? = nil, list: String, startDate: DateComponents? = nil,
                dueDate: DateComponents? = nil, priority: Int = 0, isCompleted: Bool = false, creationDate: Date? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.list = list; self.startDate = startDate
        self.dueDate = dueDate; self.priority = priority; self.isCompleted = isCompleted; self.creationDate = creationDate
    }

    public var header: Header? { Header.parse(notes).header }
    public var body: String { Header.parse(notes).body }

    /// Content hash used by the ledger to detect edits.
    public var contentHash: String {
        "\(title)|\(notes ?? "")|\(list)|\(isCompleted)".hashValueStable
    }
}

public struct NewReminder: Sendable {
    public var title: String
    public var notes: String?
    public var list: String
    public var startDate: DateComponents?
    public var dueDate: DateComponents?
    public init(title: String, notes: String? = nil, list: String, startDate: DateComponents? = nil, dueDate: DateComponents? = nil) {
        self.title = title; self.notes = notes; self.list = list; self.startDate = startDate; self.dueDate = dueDate
    }
}

public struct NewEvent: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var notes: String?
    public init(title: String, start: Date, end: Date, allDay: Bool, notes: String? = nil) {
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.notes = notes
    }
}

/// Everything Clarify does to Reminders and Calendar goes through this protocol.
/// `EventKitStore` is the real one, `MemoryStore` backs the tests and the eval.
public protocol Store: AnyObject, Sendable {
    func listNames() async throws -> [String]
    func ensureLists(_ names: [String]) async throws
    func inboxListName() async throws -> String
    func reminders(in list: String, includeCompleted: Bool) async throws -> [ReminderItem]
    func reminder(id: String) async throws -> ReminderItem?
    @discardableResult func create(_ new: NewReminder) async throws -> ReminderItem
    func save(_ item: ReminderItem) async throws
    @discardableResult func createEvent(_ event: NewEvent) async throws -> String
    /// Titles of calendar events on the given day, with a time prefix for timed events.
    func events(on day: Date) async throws -> [String]
}

public extension Store {
    func ensureBuckets() async throws {
        try await ensureLists(Bucket.allCases.map(\.rawValue))
    }
}

extension String {
    /// FNV-1a, stable across processes unlike `hashValue`.
    var hashValueStable: String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
