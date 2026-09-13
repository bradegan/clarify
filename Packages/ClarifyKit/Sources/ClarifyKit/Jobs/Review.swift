import Foundation

/// Daily and weekly sweeps. Findings are deterministic; the model only writes
/// the one-line prompt for each.
public struct Review: Sendable {
    let services: Services
    public init(_ services: Services) { self.services = services }

    public struct Finding: Equatable, Sendable {
        public enum Rule: String, Sendable { case staleAction, projectWithoutAction, waitingOverdue, somedayOld, goalWithoutProject }
        public var rule: Rule
        public var title: String
        public var reminderID: String?
        public init(rule: Rule, title: String, reminderID: String? = nil) { self.rule = rule; self.title = title; self.reminderID = reminderID }
    }

    public static let staleActionDays = 7
    public static let waitingOverdueDays = 5
    public static let somedayOldDays = 30

    /// Tickler: anything whose start date is today or earlier moves to the inbox.
    @discardableResult
    public func dailySweep() async throws -> [ReminderItem] {
        let today = Calendar.current.startOfDay(for: services.now())
        let inbox = try await services.store.inboxListName()
        var moved: [ReminderItem] = []
        for list in [Bucket.someday.rawValue, Bucket.projects.rawValue] {
            for var item in try await services.store.reminders(in: list, includeCompleted: false) {
                guard item.dueDate == nil, let comps = item.startDate, let start = Calendar.current.date(from: comps), start <= today else { continue }
                item.list = inbox
                item.startDate = nil
                try await services.store.save(item)
                moved.append(item)
            }
        }
        if !moved.isEmpty { services.log("Tickler surfaced \(moved.count) item(s)") }
        return moved
    }

    /// Today's calendar plus the top three next actions, for the morning notification.
    public func morningBriefing() async throws -> String {
        let now = services.now()
        let events = try await services.store.events(on: now)
        let actions = try await services.store.reminders(in: Bucket.nextActions.rawValue, includeCompleted: false)
        let top = Engage.filter(actions, .init(), now: now).prefix(3).map(\.title)
        var lines: [String] = []
        lines.append(events.isEmpty ? "No events today." : "Today: " + events.joined(separator: "; "))
        lines.append(top.isEmpty ? "No next actions." : "Next: " + top.joined(separator: "; "))
        return lines.joined(separator: "\n")
    }

    public func findings() async throws -> [Finding] {
        let now = services.now()
        var out: [Finding] = []
        func ageDays(_ item: ReminderItem) -> Int {
            let since = item.header?["since"].flatMap(DateOnly.parse) ?? item.creationDate ?? now
            return Calendar.current.dateComponents([.day], from: since, to: now).day ?? 0
        }
        let actions = try await services.store.reminders(in: Bucket.nextActions.rawValue, includeCompleted: false)
        for a in actions where a.dueDate == nil && ageDays(a) >= Review.staleActionDays {
            out.append(Finding(rule: .staleAction, title: a.title, reminderID: a.id))
        }
        let projects = try await services.store.reminders(in: Bucket.projects.rawValue, includeCompleted: false)
        for p in projects where !actions.contains(where: { $0.header?["project"] == p.title }) {
            out.append(Finding(rule: .projectWithoutAction, title: p.title, reminderID: p.id))
        }
        for w in try await services.store.reminders(in: Bucket.waitingFor.rawValue, includeCompleted: false) where ageDays(w) >= Review.waitingOverdueDays {
            out.append(Finding(rule: .waitingOverdue, title: w.title, reminderID: w.id))
        }
        for s in try await services.store.reminders(in: Bucket.someday.rawValue, includeCompleted: false) where ageDays(s) >= Review.somedayOldDays {
            out.append(Finding(rule: .somedayOld, title: s.title, reminderID: s.id))
        }
        let goals = try await Clarifier(services).areasText().components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.lowercased().hasPrefix("goal:") }
            .map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
        for g in goals where !projects.contains(where: { Review.shareSignificantWord(g, $0.title + " " + $0.body) }) {
            out.append(Finding(rule: .goalWithoutProject, title: g))
        }
        return out
    }

    /// Runs the weekly review and writes a checklist into the Weekly Review list.
    /// The lines are deterministic: on the gold runs the wording below beat what
    /// small models produced, and a review should never depend on a model call.
    @discardableResult
    public func weekly() async throws -> [ReminderItem] {
        let found = try await findings()
        var created: [ReminderItem] = []
        let stamp = DateOnly.string(services.now())
        for finding in found {
            let header = Header(["kind": "review", "rule": finding.rule.rawValue, "since": stamp, "for": finding.reminderID ?? ""])
            created.append(try await services.store.create(NewReminder(title: Review.line(for: finding), notes: header.render(body: finding.title), list: Bucket.weeklyReview.rawValue)))
        }
        services.log("Weekly review: \(created.count) item(s)")
        return created
    }

    /// A goal counts as covered when any word of four or more letters from it
    /// appears in a project's title or notes.
    static func shareSignificantWord(_ goal: String, _ text: String) -> Bool {
        let haystack = text.lowercased()
        return goal.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0.count >= 4 }.contains { haystack.contains($0) }
    }

    public static func line(for f: Finding) -> String {
        switch f.rule {
        case .staleAction: return "Still doing '\(f.title)'? Do it, defer it, or drop it."
        case .projectWithoutAction: return "Project '\(f.title)' has no next action. Add one."
        case .waitingOverdue: return "Follow up on '\(f.title)'."
        case .somedayOld: return "Still want '\(f.title)'? Activate it or let it go."
        case .goalWithoutProject: return "Goal '\(f.title)' has no project. Start one?"
        }
    }
}
