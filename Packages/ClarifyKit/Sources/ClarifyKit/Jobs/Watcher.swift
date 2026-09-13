import Foundation

/// Waiting For watcher: matches new mail against open Waiting For items by sender.
public struct Watcher: Sendable {
    let services: Services
    public init(_ services: Services) { self.services = services }

    public struct Hit: Sendable {
        public var waiting: ReminderItem
        public var message: MailMessage
        public var verdict: WatcherVerdict
    }

    @discardableResult
    public func scan(since: Date) async throws -> [Hit] {
        let waiting = try await services.store.reminders(in: Bucket.waitingFor.rawValue, includeCompleted: false)
        guard !waiting.isEmpty else { return [] }
        let messages = try await services.mail.inbox(since: since)
        var hits: [Hit] = []
        for message in messages {
            for item in waiting {
                guard let who = item.header?["delegated_to"], Watcher.matches(sender: message.sender, person: who) else { continue }
                let input = "Waiting for: \(item.title)\nFrom: \(who)\nEmail from \(message.sender), subject '\(message.subject)':\n\(message.excerpt)"
                let verdict = try await services.model.respond(instructions: Prompts.text("watcher"), input: input, as: WatcherVerdict.self)
                try verdict.validate()
                guard verdict.closes else { continue }
                hits.append(Hit(waiting: item, message: message, verdict: verdict))
                if services.settings.autoCloseWaiting {
                    var closed = item
                    closed.isCompleted = true
                    closed.notes = (item.header ?? Header()).render(body: item.body + "\nClosed: \"\(verdict.quote)\"")
                    try await services.store.save(closed)
                    services.log("Closed '\(item.title)' from mail")
                } else {
                    let approve = try await services.store.create(NewReminder(
                        title: "\(who) replied. Close '\(item.title)'?",
                        notes: Header(["kind": "approval", "for": item.id, "reason": "Mail from \(message.sender): \"\(verdict.quote)\""]).render(body: ""),
                        list: Bucket.approve.rawValue))
                    try await services.ledger.record(approve.id, hash: approve.contentHash, pending: .closeWaiting(reminderID: item.id, quote: verdict.quote))
                }
            }
        }
        return hits
    }

    /// A sender matches when the delegated name appears in the sender string,
    /// or when the delegated value is an address contained in the sender.
    static func matches(sender: String, person: String) -> Bool {
        let s = sender.lowercased(), p = person.lowercased().trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return false }
        if p.contains("@") { return s.contains(p) }
        return p.split(separator: " ").allSatisfy { s.contains($0) }
    }
}
