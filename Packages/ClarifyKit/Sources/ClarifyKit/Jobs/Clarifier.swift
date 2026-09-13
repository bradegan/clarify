import Foundation

/// Everything the jobs need, injected so tests run with fakes.
public struct Services: Sendable {
    public var store: Store
    public var model: LanguageModel
    public var ledger: Ledger
    public var contacts: ContactsBridge
    public var files: FilesBridge
    public var mail: MailBridge
    public var messages: MessagesBridge
    public var toolModel: ToolChatModel?
    public var web: WebSearchBridge?
    public var settings: Settings
    public var now: @Sendable () -> Date
    public var log: Logger

    public init(store: Store, model: LanguageModel, ledger: Ledger, contacts: ContactsBridge, files: FilesBridge,
                mail: MailBridge, messages: MessagesBridge, settings: Settings, toolModel: ToolChatModel? = nil,
                web: WebSearchBridge? = nil, now: @escaping @Sendable () -> Date = { Date() }, log: @escaping Logger = silentLogger) {
        self.store = store; self.model = model; self.ledger = ledger; self.contacts = contacts; self.files = files
        self.mail = mail; self.messages = messages; self.toolModel = toolModel; self.web = web; self.settings = settings; self.now = now; self.log = log
    }
}

/// Clarifies one inbox item: one model call, then deterministic Store mutations.
public struct Clarifier: Sendable {
    let services: Services
    public init(_ services: Services) { self.services = services }

    public static let areasTitle = "Areas and Goals"

    public func areasText() async throws -> String {
        let refs = try await services.store.reminders(in: Bucket.reference.rawValue, includeCompleted: false)
        return refs.first { $0.title == Clarifier.areasTitle }?.body ?? ""
    }

    public func decide(_ item: ReminderItem) async throws -> ClarifyDecision {
        let input = """
        Inbox item: \(item.title)
        Notes: \(item.body.isEmpty ? "(none)" : item.body)
        Today: \(DateOnly.string(services.now()))
        Contexts: \(services.settings.contexts.joined(separator: " "))
        Areas: \(try await areasText().isEmpty ? "(none listed)" : try await areasText())
        """
        let decision = try await services.model.respond(instructions: Prompts.text("clarify"), input: input, as: ClarifyDecision.self)
        try decision.validate()
        return decision
    }

    /// Processes every unprocessed inbox item. Returns the items it touched.
    @discardableResult
    public func processInbox() async throws -> [ReminderItem] {
        let inbox = try await services.store.inboxListName()
        let items = try await services.store.reminders(in: inbox, includeCompleted: false)
        var touched: [ReminderItem] = []
        for item in items where await !services.ledger.isProcessed(item) {
            do {
                try await process(item)
                touched.append(item)
            } catch let error as ModelError {
                if case .authFailed = error { throw error }
                services.log("Skipped '\(item.title)': \(error.localizedDescription)")
            } catch {
                services.log("Skipped '\(item.title)': \(error.localizedDescription)")
            }
        }
        return touched
    }

    /// Records inbox items as seen without touching them. Used on first run.
    public func markInboxSeen() async throws -> Int {
        let inbox = try await services.store.inboxListName()
        let items = try await services.store.reminders(in: inbox, includeCompleted: false)
        for item in items { try await services.ledger.record(item.id, hash: item.contentHash) }
        return items.count
    }

    public func process(_ item: ReminderItem) async throws {
        let decision = try await decide(item)
        var updated = item
        var header = Header()
        header["kind"] = decision.kind
        header["since"] = DateOnly.string(services.now())
        header["reason"] = decision.reason
        if !decision.outcome.isEmpty { header["outcome"] = decision.outcome }
        if decision.area != "Unsorted", !decision.area.isEmpty { header["area"] = decision.area }

        switch decision.kindValue {
        case .trash:
            updated.list = Bucket.trash.rawValue
        case .reference:
            updated.list = Bucket.reference.rawValue
        case .someday:
            updated.list = Bucket.someday.rawValue
        case .calendar:
            guard let parsed = ISO8601.parse(decision.date) else { throw ModelError.invalidOutput("calendar without date") }
            let end = parsed.hasTime ? parsed.date.addingTimeInterval(3600) : parsed.date
            let eventID = try await services.store.createEvent(NewEvent(title: item.title, start: parsed.date, end: end, allDay: !parsed.hasTime, notes: decision.reason))
            header["event"] = "\(decision.date) \(eventID)"
            if !decision.nextAction.isEmpty {
                try await createNextAction(decision.nextAction, decision: decision, project: nil, header: header)
            }
            updated.isCompleted = true
        case .waiting:
            updated.list = Bucket.waitingFor.rawValue
            header["delegated_to"] = decision.delegatedTo
            updated.title = item.title
        case .action:
            updated.list = Bucket.nextActions.rawValue
            updated.title = Clarifier.prefixed(decision.nextAction, with: decision.context)
            header["context"] = decision.context
            header["minutes"] = String(decision.minutes)
            header["energy"] = decision.energy
            if decision.recipeValue != .none { header["recipe"] = decision.recipe }
        case .project:
            updated.list = Bucket.projects.rawValue
            updated.title = decision.outcome.isEmpty ? item.title : decision.outcome
            header["project"] = updated.title
            let plan = try await Planner(services).generate(project: updated.title, body: item.body)
            updated.notes = header.apply(to: item.notes)
            try await services.store.save(updated)
            try await services.ledger.record(item.id, hash: updated.contentHash)
            try await Planner(services).apply(plan, to: updated, energy: decision.energy)
            services.log("Clarified '\(item.title)' as project")
            return
        }
        updated.notes = header.apply(to: item.notes)
        try await services.store.save(updated)
        try await services.ledger.record(item.id, hash: updated.contentHash)
        services.log("Clarified '\(item.title)' as \(decision.kind)")

        if decision.kindValue == .action, services.settings.autoRunRecipes {
            // The model's needsPrep flag, with a deterministic backstop: any recipe
            // (a message, an email, a lookup, an event) always needs preparation.
            if services.toolModel != nil, decision.needsPrep || decision.recipeValue != .none {
                _ = try await ToolLoop(services).run(item: updated, goal: decision.nextAction)
            } else if services.toolModel == nil, decision.recipeValue != .none,
                      decision.minutes <= services.settings.twoMinuteThreshold {
                try await Recipes(services).run(decision.recipeValue, for: updated, decision: decision)
            }
        }
    }

    func createNextAction(_ action: String, decision: ClarifyDecision, project: String?, header base: Header) async throws {
        var header = base
        header["kind"] = Kind.action.rawValue
        header["context"] = decision.context
        header["minutes"] = String(decision.minutes)
        header["energy"] = decision.energy
        if let project { header["project"] = project }
        try await services.store.create(NewReminder(title: Clarifier.prefixed(action, with: decision.context),
                                                    notes: header.render(body: ""), list: Bucket.nextActions.rawValue))
    }

    static func prefixed(_ title: String, with context: String) -> String {
        let clean = title.trimmingCharacters(in: .whitespaces)
        guard !context.isEmpty, !clean.hasPrefix(context) else { return clean }
        return "\(context) \(clean)"
    }
}

public enum DateOnly {
    public static func string(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: date)
    }
    public static func parse(_ text: String) -> Date? { ISO8601.parse(text)?.date }
}
