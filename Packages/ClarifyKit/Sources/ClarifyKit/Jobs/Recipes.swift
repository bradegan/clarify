import Foundation

/// The two-minute rule, as a closed set of pipelines. Every recipe ends in an
/// Approve reminder or a note, never in something leaving the Mac.
public struct Recipes: Sendable {
    let services: Services
    public init(_ services: Services) { self.services = services }

    public func run(_ recipe: Recipe, for item: ReminderItem, decision: ClarifyDecision) async throws {
        guard recipe != .none else { return }
        let input = "Recipe: \(recipe.rawValue)\nInbox item: \(item.title)\nNext action: \(decision.nextAction)\nNotes: \(item.body)\nToday: \(DateOnly.string(services.now()))"
        let slots = try await services.model.respond(instructions: Prompts.text("recipe"), input: input, as: RecipeSlots.self)
        do {
            try slots.validate(for: recipe)
        } catch {
            try await annotate(item, "Recipe \(recipe.rawValue) skipped: \(error.localizedDescription)")
            return
        }
        switch recipe {
        case .emailWithAttachment: try await email(item, slots)
        case .message: try await message(item, slots)
        case .calendarEvent: try await calendarEvent(item, slots)
        case .contactLookup: try await contactLookup(item, slots)
        case .fileLookup: try await fileLookup(item, slots)
        case .none: break
        }
    }

    // MARK: recipes

    func email(_ item: ReminderItem, _ slots: RecipeSlots) async throws {
        let people = try await services.contacts.lookup(name: slots.recipientName)
        guard let person = people.first else {
            try await annotate(item, "No contact named \(slots.recipientName). Add them to Contacts, then re-add this item.")
            return
        }
        guard let email = person.emails.first else {
            try await annotate(item, "\(person.name) has no email in Contacts. Add one, then re-add this item.")
            return
        }
        if people.count > 1 {
            try await annotate(item, "Several contacts match \(slots.recipientName); used \(person.name).")
        }
        let files = try await services.files.find(query: slots.attachmentQuery, limit: 3)
        switch files.count {
        case 0:
            try await annotate(item, "No file found for '\(slots.attachmentQuery)'. Draft not created.")
        case 1:
            try await services.mail.draft(to: email, subject: slots.subject, body: slots.body, attachment: files[0])
            try await annotate(item, "Draft created in Mail to \(email) with \(files[0].lastPathComponent). Waiting for approval.")
            let approve = try await services.store.create(NewReminder(
                title: "Send '\(slots.subject)' to \(person.name)?",
                notes: Header(["kind": "approval", "for": item.id, "reason": "Completing this sends the Mail draft with \(files[0].lastPathComponent)."]).render(body: ""),
                list: Bucket.approve.rawValue))
            try await services.ledger.record(approve.id, hash: approve.contentHash,
                                             pending: .sendMail(to: email, subject: slots.subject, body: slots.body, attachment: files[0].path))
        default:
            for file in files {
                let approve = try await services.store.create(NewReminder(
                    title: "Attach \(file.lastPathComponent) for '\(slots.subject)'?",
                    notes: Header(["kind": "approval", "for": item.id, "reason": "Several files matched '\(slots.attachmentQuery)'. Complete one to choose it."]).render(body: file.path),
                    list: Bucket.approve.rawValue))
                try await services.ledger.record(approve.id, hash: approve.contentHash,
                                                 pending: .chooseAttachment(reminderID: item.id, path: file.path, to: email, subject: slots.subject, body: slots.body))
            }
            try await annotate(item, "\(files.count) files match '\(slots.attachmentQuery)'. Choose one in Approve.")
        }
    }

    func message(_ item: ReminderItem, _ slots: RecipeSlots) async throws {
        guard Recipes.isRealBody(slots.body, itemTitle: item.title) else {
            try await annotate(item, "Could not tell what to text \(slots.recipientName). Put the message in the notes and re-add this item.")
            return
        }
        let people = try await services.contacts.lookup(name: slots.recipientName)
        guard let person = people.first, let phone = person.phones.first else {
            try await annotate(item, "No phone for \(slots.recipientName) in Contacts.")
            return
        }
        let approve = try await services.store.create(NewReminder(
            title: "Text \(person.name): \"\(slots.body)\"?",
            notes: Header(["kind": "approval", "for": item.id, "reason": "Completing this sends the text through Messages."]).render(body: ""),
            list: Bucket.approve.rawValue))
        try await services.ledger.record(approve.id, hash: approve.contentHash, pending: .sendMessage(handle: phone, text: slots.body))
        try await annotate(item, "Text to \(person.name) waiting for approval.")
    }

    func calendarEvent(_ item: ReminderItem, _ slots: RecipeSlots) async throws {
        guard let start = ISO8601.parse(slots.start) else { return }
        let end = ISO8601.parse(slots.end)?.date ?? start.date.addingTimeInterval(3600)
        let id = try await services.store.createEvent(NewEvent(title: slots.eventTitle, start: start.date, end: end, allDay: !start.hasTime))
        try await annotate(item, "Event '\(slots.eventTitle)' created (\(id)).")
    }

    func contactLookup(_ item: ReminderItem, _ slots: RecipeSlots) async throws {
        let people = try await services.contacts.lookup(name: slots.recipientName)
        guard let person = people.first else {
            try await annotate(item, "No contact named \(slots.recipientName).")
            return
        }
        let lines = ["\(person.name)"] + person.phones.map { "phone: \($0)" } + person.emails.map { "email: \($0)" } + person.addresses.map { "address: \($0)" }
        try await annotate(item, lines.joined(separator: "\n"))
    }

    func fileLookup(_ item: ReminderItem, _ slots: RecipeSlots) async throws {
        let files = try await services.files.find(query: slots.attachmentQuery, limit: 5)
        try await annotate(item, files.isEmpty ? "No file found for '\(slots.attachmentQuery)'." : files.map(\.path).joined(separator: "\n"))
    }

    /// A body that merely restates the instruction ("text Alex the address") is
    /// not a message. The model must have found actual content in the item.
    static func isRealBody(_ body: String, itemTitle: String) -> Bool {
        let normalize: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces) }
        let b = normalize(body), t = normalize(itemTitle.replacingOccurrences(of: "^@\\S+\\s*", with: "", options: .regularExpression))
        guard !b.isEmpty else { return false }
        let verbs = ["text ", "send ", "message ", "email ", "tell "]
        return b != t && !verbs.contains { b.hasPrefix($0) }
    }

    // MARK: approvals

    /// Executes the pending action behind a completed Approve reminder.
    public func approve(_ reminder: ReminderItem) async throws {
        guard let entry = await services.ledger.entry(for: reminder.id), let pending = entry.pending else { return }
        switch pending {
        case .sendMail(let to, let subject, let body, let attachment):
            try await services.mail.send(to: to, subject: subject, body: body, attachment: attachment.map { URL(fileURLWithPath: $0) })
            try await moveSourceToWaiting(for: reminder, delegatedTo: to, note: "Sent '\(subject)' to \(to).")
        case .sendMessage(let handle, let text):
            try await services.messages.send(text: text, to: handle)
            try await moveSourceToWaiting(for: reminder, delegatedTo: handle, note: "Sent text to \(handle): \(text)")
        case .chooseAttachment(let sourceID, let path, let to, let subject, let body):
            try await services.mail.draft(to: to, subject: subject, body: body, attachment: URL(fileURLWithPath: path))
            let approve = try await services.store.create(NewReminder(
                title: "Send '\(subject)' to \(to)?",
                notes: Header(["kind": "approval", "for": sourceID, "reason": "Completing this sends the Mail draft with \((path as NSString).lastPathComponent)."]).render(body: ""),
                list: Bucket.approve.rawValue))
            try await services.ledger.record(approve.id, hash: approve.contentHash, pending: .sendMail(to: to, subject: subject, body: body, attachment: path))
            try await retireSiblingChoices(of: reminder, sourceID: sourceID)
        case .answerQuestion(let sourceID, let question):
            let answer = reminder.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let source = try await services.store.reminder(id: sourceID) {
                let prior = "Q: \(question)\nA: \(answer.isEmpty ? "(no answer given)" : answer)"
                if services.toolModel != nil {
                    _ = try await ToolLoop(services).run(item: source, goal: source.header?["reason"] ?? source.title, priorAnswers: prior)
                }
            }
        case .closeWaiting(let sourceID, let quote):
            if var source = try await services.store.reminder(id: sourceID) {
                source.isCompleted = true
                source.notes = (source.notes ?? "") + "\nClosed: \"\(quote)\""
                try await services.store.save(source)
            }
        }
        try await services.ledger.setPending(reminder.id, nil)
        services.log("Approved '\(reminder.title)'")
    }

    func moveSourceToWaiting(for approval: ReminderItem, delegatedTo: String, note: String) async throws {
        guard let sourceID = approval.header?["for"], var source = try await services.store.reminder(id: sourceID) else { return }
        var header = source.header ?? Header()
        header["kind"] = Kind.waiting.rawValue
        header["delegated_to"] = delegatedTo
        header["since"] = DateOnly.string(services.now())
        source.list = Bucket.waitingFor.rawValue
        source.notes = header.render(body: source.body + "\n" + note)
        try await services.store.save(source)
        try await services.ledger.record(source.id, hash: source.contentHash)
    }

    func retireSiblingChoices(of chosen: ReminderItem, sourceID: String) async throws {
        let approvals = try await services.store.reminders(in: Bucket.approve.rawValue, includeCompleted: false)
        for var a in approvals where a.id != chosen.id && a.header?["for"] == sourceID {
            if case .chooseAttachment? = await services.ledger.entry(for: a.id)?.pending {
                a.list = Bucket.trash.rawValue
                try await services.store.save(a)
                try await services.ledger.setPending(a.id, nil)
            }
        }
    }

    func annotate(_ item: ReminderItem, _ text: String) async throws {
        guard var current = try await services.store.reminder(id: item.id) else { return }
        let header = current.header ?? Header()
        current.notes = header.render(body: current.body.isEmpty ? text : current.body + "\n" + text)
        try await services.store.save(current)
        try await services.ledger.record(current.id, hash: current.contentHash)
    }
}
