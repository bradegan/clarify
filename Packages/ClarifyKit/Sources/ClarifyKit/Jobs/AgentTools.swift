import Foundation

/// The tools the agent loop can call. Read tools run directly. Mutating tools
/// never send: they queue an Approve reminder and tell the model it is pending.
public struct AgentTools: Sendable {
    let services: Services
    let source: ReminderItem
    public init(_ services: Services, source: ReminderItem) { self.services = services; self.source = source }

    /// Set by ask_user so the loop knows to stop and wait for the human.
    public final class State: @unchecked Sendable { public var awaitingAnswer = false }
    public let state = State()

    public static func specs(contexts: [String], web: Bool) -> [ToolSpec] {
        var specs: [ToolSpec] = [
            ToolSpec(name: "lookup_contact", description: "Find a person's phone numbers and email addresses by name.",
                     parametersJSONSchema: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#, mutating: false),
            ToolSpec(name: "find_file", description: "Find files on this Mac by words in their name, newest first.",
                     parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#, mutating: false),
            ToolSpec(name: "search_calendar", description: "List the events on a given day (ISO date, e.g. 2026-09-20).",
                     parametersJSONSchema: #"{"type":"object","properties":{"date":{"type":"string"}},"required":["date"]}"#, mutating: false),
            ToolSpec(name: "read_reminders", description: "Search your reminders across all lists by words in the title.",
                     parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#, mutating: false),
            ToolSpec(name: "read_mail", description: "Search recent inbox mail by sender name or subject words.",
                     parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#, mutating: false),
            ToolSpec(name: "draft_email", description: "Prepare an email for the user to approve before it sends. Provide an email address in 'to'.",
                     parametersJSONSchema: #"{"type":"object","properties":{"to":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"},"attachment_path":{"type":"string"}},"required":["to","subject","body"]}"#, mutating: true),
            ToolSpec(name: "draft_text", description: "Prepare a text message for the user to approve before it sends. Provide a phone number in 'phone'.",
                     parametersJSONSchema: #"{"type":"object","properties":{"phone":{"type":"string"},"body":{"type":"string"}},"required":["phone","body"]}"#, mutating: true),
            ToolSpec(name: "create_event", description: "Create a calendar event. Times are ISO 8601.",
                     parametersJSONSchema: #"{"type":"object","properties":{"title":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"}},"required":["title","start"]}"#, mutating: false),
            ToolSpec(name: "ask_user", description: "Ask the user one question when you cannot proceed without their answer, then stop.",
                     parametersJSONSchema: #"{"type":"object","properties":{"question":{"type":"string"}},"required":["question"]}"#, mutating: true),
        ]
        specs.append(ToolSpec(name: "save_note", description: "Append a useful fact you found to the reminder's notes, so the user has it when they act. Use this for a phone number, address, or link the user will need.",
            parametersJSONSchema: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#, mutating: false))
        if web {
            specs.append(ToolSpec(name: "web_search", description: "Look something up on the web and get a short answer with sources. Use for facts you do not have locally, like a business's phone number or an official website.",
                parametersJSONSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#, mutating: false))
        }
        return specs
    }

    /// Runs one tool call, returns the JSON text the model sees next.
    public func run(_ call: ToolInvocation) async throws -> String {
        switch call.name {
        case "lookup_contact": return try await lookupContact(call.arg("name") ?? "")
        case "find_file": return try await findFile(call.arg("query") ?? "")
        case "search_calendar": return try await searchCalendar(call.arg("date") ?? "")
        case "read_reminders": return try await readReminders(call.arg("query") ?? "")
        case "read_mail": return try await readMail(call.arg("query") ?? "")
        case "draft_email": return try await draftEmail(call)
        case "draft_text": return try await draftText(call)
        case "create_event": return try await createEvent(call)
        case "ask_user": return try await askUser(call.arg("question") ?? "")
        case "web_search": return try await webSearch(call.arg("query") ?? "")
        case "save_note": return try await saveNote(call.arg("text") ?? "")
        default: return json(["error": "unknown tool \(call.name)"])
        }
    }

    // MARK: read tools

    func lookupContact(_ name: String) async throws -> String {
        let people = try await services.contacts.lookup(name: name)
        return json(["matches": people.map { ["name": $0.name, "phones": $0.phones, "emails": $0.emails] }])
    }

    func findFile(_ query: String) async throws -> String {
        let files = try await services.files.find(query: query, limit: 5)
        return json(["files": files.map(\.path)])
    }

    func searchCalendar(_ date: String) async throws -> String {
        guard let day = ISO8601.parse(date)?.date else { return json(["error": "date must be ISO 8601"]) }
        return json(["date": date, "events": try await services.store.events(on: day)])
    }

    func readReminders(_ query: String) async throws -> String {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var hits: [[String: String]] = []
        for list in try await services.store.listNames() {
            for r in try await services.store.reminders(in: list, includeCompleted: false) {
                let hay = r.title.lowercased()
                guard words.contains(where: { hay.contains($0) }) else { continue }
                hits.append(["list": r.list, "title": r.title, "notes": String(r.body.prefix(200))])
                if hits.count >= 8 { break }
            }
        }
        return json(["reminders": hits])
    }

    func readMail(_ query: String) async throws -> String {
        let since = services.now().addingTimeInterval(-30 * 86400)
        let words = query.lowercased().split(separator: " ").map(String.init)
        let msgs = try await services.mail.inbox(since: since).filter { m in
            let hay = (m.sender + " " + m.subject).lowercased()
            return words.isEmpty || words.contains { hay.contains($0) }
        }
        return json(["messages": msgs.prefix(5).map { ["from": $0.sender, "subject": $0.subject, "excerpt": String($0.excerpt.prefix(300))] }])
    }

    func saveNote(_ text: String) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return json(["error": "nothing to save"]) }
        guard var current = try await services.store.reminder(id: source.id) else { return json(["error": "reminder gone"]) }
        let header = current.header ?? Header()
        current.notes = header.render(body: current.body.isEmpty ? text : current.body + "\n" + text)
        try await services.store.save(current)
        try await services.ledger.record(current.id, hash: current.contentHash)
        return json(["status": "saved to the reminder's notes"])
    }

    func webSearch(_ query: String) async throws -> String {
        guard let web = services.web else { return json(["error": "web search is not configured"]) }
        let result = try await web.answer(query)
        return json(["answer": result.answer, "sources": result.sources.map { ["title": $0.title, "url": $0.url] }])
    }

    // MARK: mutating tools -> Approve

    func draftEmail(_ call: ToolInvocation) async throws -> String {
        let to = call.arg("to") ?? "", subject = call.arg("subject") ?? "", body = call.arg("body") ?? ""
        guard to.contains("@") else { return json(["error": "need a real email address in 'to'; use lookup_contact first"]) }
        let attachment = call.arg("attachment_path").flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        try await services.mail.draft(to: to, subject: subject, body: body, attachment: attachment)
        let approve = try await services.store.create(NewReminder(
            title: "Send '\(subject)' to \(to)?",
            notes: Header(["kind": "approval", "for": source.id,
                           "reason": "Completing this sends the Mail draft" + (attachment.map { " with \($0.lastPathComponent)" } ?? "") + "."]).render(body: ""),
            list: Bucket.approve.rawValue))
        try await services.ledger.record(approve.id, hash: approve.contentHash,
                                         pending: .sendMail(to: to, subject: subject, body: body, attachment: attachment?.path))
        return json(["status": "draft queued for approval", "to": to, "subject": subject])
    }

    func draftText(_ call: ToolInvocation) async throws -> String {
        let phone = call.arg("phone") ?? "", body = call.arg("body") ?? ""
        guard phone.contains(where: \.isNumber) else { return json(["error": "need a phone number; use lookup_contact first"]) }
        let approve = try await services.store.create(NewReminder(
            title: "Text \(phone): \"\(body)\"?",
            notes: Header(["kind": "approval", "for": source.id, "reason": "Completing this sends the text through Messages."]).render(body: ""),
            list: Bucket.approve.rawValue))
        try await services.ledger.record(approve.id, hash: approve.contentHash, pending: .sendMessage(handle: phone, text: body))
        return json(["status": "text queued for approval", "phone": phone])
    }

    func createEvent(_ call: ToolInvocation) async throws -> String {
        guard let start = ISO8601.parse(call.arg("start") ?? "") else { return json(["error": "start must be ISO 8601"]) }
        let end = ISO8601.parse(call.arg("end") ?? "")?.date ?? start.date.addingTimeInterval(3600)
        let id = try await services.store.createEvent(NewEvent(title: call.arg("title") ?? "Event", start: start.date, end: end, allDay: !start.hasTime))
        return json(["status": "event created", "id": id])
    }

    func askUser(_ question: String) async throws -> String {
        state.awaitingAnswer = true
        let approve = try await services.store.create(NewReminder(
            title: "Answer for '\(source.title)': \(question)",
            notes: Header(["kind": "question", "for": source.id, "reason": "Type your answer in these notes, then complete this reminder."]).render(body: ""),
            list: Bucket.approve.rawValue))
        try await services.ledger.record(approve.id, hash: approve.contentHash, pending: .answerQuestion(sourceID: source.id, question: question))
        return json(["status": "asked the user; waiting for their answer"])
    }

    func json(_ obj: Any) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: obj), encoding: .utf8)) ?? "{}"
    }
}
