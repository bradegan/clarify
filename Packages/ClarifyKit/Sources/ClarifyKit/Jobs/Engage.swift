import Foundation

/// The four-criteria model: context, time, energy, then priority by due date and age.
/// The model only parses the request. The filter is deterministic over headers.
public struct Engage: Sendable {
    let services: Services
    public init(_ services: Services) { self.services = services }

    public struct Criteria: Equatable, Sendable {
        public var context: String?
        public var minutes: Int?
        public var energy: Energy?
        public init(context: String? = nil, minutes: Int? = nil, energy: Energy? = nil) {
            self.context = context; self.minutes = minutes; self.energy = energy
        }
    }

    public func parse(_ request: String) async throws -> Criteria {
        let query = try await services.model.respond(instructions: Prompts.text("engage"),
                                                     input: "Request: \(request)\nContexts: \(services.settings.contexts.joined(separator: " "))",
                                                     as: EngageQuery.self)
        try query.validate()
        return Criteria(context: query.context.isEmpty ? nil : query.context,
                        minutes: query.minutes == 0 ? nil : query.minutes,
                        energy: Energy(rawValue: query.energy))
    }

    public func candidates(_ criteria: Criteria, limit: Int = 5) async throws -> [ReminderItem] {
        let actions = try await services.store.reminders(in: Bucket.nextActions.rawValue, includeCompleted: false)
        return Engage.filter(actions, criteria, now: services.now()).prefix(limit).map { $0 }
    }

    public static func filter(_ actions: [ReminderItem], _ c: Criteria, now: Date) -> [ReminderItem] {
        actions.filter { item in
            let h = item.header
            if let context = c.context {
                let itemContext = h?["context"] ?? ""
                guard itemContext == context || itemContext == "@anywhere" else { return false }
            }
            if let budget = c.minutes, let m = h?["minutes"].flatMap(Int.init) {
                guard m <= budget else { return false }
            }
            if let energy = c.energy, let e = h?["energy"].flatMap(Energy.init(rawValue:)) {
                guard e.rank <= energy.rank else { return false }
            }
            return true
        }.sorted { a, b in
            switch (a.dueDate.flatMap(Calendar.current.date(from:)), b.dueDate.flatMap(Calendar.current.date(from:))) {
            case let (x?, y?) where x != y: return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            default: break
            }
            let ageA = a.header?["since"].flatMap(DateOnly.parse) ?? a.creationDate ?? now
            let ageB = b.header?["since"].flatMap(DateOnly.parse) ?? b.creationDate ?? now
            return ageA < ageB
        }
    }

    /// Copies the chosen candidates into the Today list.
    public func stage(_ items: [ReminderItem]) async throws {
        for item in items {
            try await services.store.create(NewReminder(title: item.title, notes: item.notes, list: Bucket.today.rawValue, dueDate: item.dueDate))
        }
    }
}
