import Foundation
@testable import ClarifyKit

/// Returns canned outputs by type, in order, and records every call.
final class FakeModel: LanguageModel, @unchecked Sendable {
    let name = "fake"
    private let lock = NSLock()
    var decisions: [ClarifyDecision] = []
    var slots: [RecipeSlots] = []
    var plans: [ProjectPlan] = []
    var verdicts: [WatcherVerdict] = []
    var queries: [EngageQuery] = []
    private(set) var inputs: [String] = []

    func respond<T: ClarifyOutput>(instructions: String, input: String, as type: T.Type) async throws -> T {
        try next(type, input: input)
    }

    private func next<T: ClarifyOutput>(_ type: T.Type, input: String) throws -> T {
        lock.lock(); defer { lock.unlock() }
        inputs.append(input)
        func pop<U>(_ arr: inout [U]) throws -> U {
            guard !arr.isEmpty else { throw ModelError.emptyResponse }
            return arr.removeFirst()
        }
        switch type {
        case is ClarifyDecision.Type: return try pop(&decisions) as! T
        case is RecipeSlots.Type: return try pop(&slots) as! T
        case is ProjectPlan.Type: return try pop(&plans) as! T
        case is WatcherVerdict.Type: return try pop(&verdicts) as! T
        case is EngageQuery.Type: return try pop(&queries) as! T
        default: fatalError("unexpected type \(type)")
        }
    }
}

/// Returns scripted assistant turns in order, recording the tools it was offered.
final class FakeToolModel: ToolChatModel, @unchecked Sendable {
    let name = "fake-tools"
    private let lock = NSLock()
    var turns: [AssistantTurn] = []
    private(set) var conversations: [[ChatMessage]] = []
    func converse(system: String, messages: [ChatMessage], tools: [ToolSpec]) async throws -> AssistantTurn {
        lock.lock(); defer { lock.unlock() }
        conversations.append(messages)
        guard !turns.isEmpty else { return AssistantTurn(text: "done", toolCalls: []) }
        return turns.removeFirst()
    }
}

func toolCall(_ name: String, _ args: [String: String]) -> ToolInvocation {
    let json = (try? String(data: JSONSerialization.data(withJSONObject: args), encoding: .utf8)) ?? "{}"
    return ToolInvocation(id: "tc-\(name)-\(Int.random(in: 0...9999))", name: name, arguments: json)
}

final class FakeContacts: ContactsBridge, @unchecked Sendable {
    var people: [ContactMatch] = []
    func lookup(name: String) async throws -> [ContactMatch] {
        people.filter { $0.name.localizedCaseInsensitiveContains(name) }
    }
}

final class FakeFiles: FilesBridge, @unchecked Sendable {
    var results: [URL] = []
    func find(query: String, limit: Int) async throws -> [URL] { Array(results.prefix(limit)) }
}

final class FakeMail: MailBridge, @unchecked Sendable {
    struct Sent: Equatable { var to: String; var subject: String; var body: String; var attachment: URL? }
    var drafts: [Sent] = []
    var sent: [Sent] = []
    var messages: [MailMessage] = []
    func draft(to: String, subject: String, body: String, attachment: URL?) async throws { drafts.append(Sent(to: to, subject: subject, body: body, attachment: attachment)) }
    func send(to: String, subject: String, body: String, attachment: URL?) async throws { sent.append(Sent(to: to, subject: subject, body: body, attachment: attachment)) }
    func inbox(since: Date) async throws -> [MailMessage] { messages.filter { $0.received >= since } }
}

final class FakeMessages: MessagesBridge, @unchecked Sendable {
    var sent: [(String, String)] = []
    func send(text: String, to handle: String) async throws { sent.append((handle, text)) }
}

final class FakeWeb: WebSearchBridge, @unchecked Sendable {
    var result = WebAnswer(answer: "", sources: [])
    private(set) var queries: [String] = []
    func answer(_ query: String) async throws -> WebAnswer { queries.append(query); return result }
}

struct Harness {
    let store = MemoryStore()
    let model = FakeModel()
    let ledger = Ledger(url: nil)
    let contacts = FakeContacts()
    let files = FakeFiles()
    let mail = FakeMail()
    let messages = FakeMessages()
    let toolModel = FakeToolModel()
    let web = FakeWeb()
    var useToolModel = false
    var useWeb = false
    var settings = Settings()
    var now = Date(timeIntervalSince1970: 1_789_200_000)
    var logs: [String] = []

    func services() -> Services {
        let now = self.now
        return Services(store: store, model: model, ledger: ledger, contacts: contacts, files: files, mail: mail,
                        messages: messages, settings: settings, toolModel: useToolModel ? toolModel : nil,
                        web: useWeb ? web : nil, now: { now }, log: { _ in })
    }

    @discardableResult
    func inbox(_ title: String, notes: String? = nil) async throws -> ReminderItem {
        try await store.create(NewReminder(title: title, notes: notes, list: store.inboxListName()))
    }
}

extension ClarifyDecision {
    static func make(kind: Kind, nextAction: String = "Do the thing", context: String = "@computer", minutes: Int = 5,
                     energy: Energy = .low, outcome: String = "", date: String = "", delegatedTo: String = "",
                     recipe: Recipe = .none, area: String = "Unsorted", reason: String = "because", needsPrep: Bool = false) -> ClarifyDecision {
        ClarifyDecision(actionable: kind != .trash && kind != .reference, kind: kind.rawValue, outcome: outcome, nextAction: nextAction,
                        context: context, minutes: minutes, energy: energy.rawValue, area: area, date: date,
                        delegatedTo: delegatedTo, recipe: recipe.rawValue, reason: reason, needsPrep: needsPrep)
    }
}

extension RecipeSlots {
    static func make(recipient: String = "", subject: String = "", body: String = "", attachment: String = "",
                     eventTitle: String = "", start: String = "", end: String = "", field: String = "") -> RecipeSlots {
        RecipeSlots(recipientName: recipient, subject: subject, body: body, attachmentQuery: attachment,
                    eventTitle: eventTitle, start: start, end: end, contactField: field)
    }
}

extension ProjectPlan {
    static func sample() -> ProjectPlan {
        ProjectPlan(purpose: "Travel freely", principles: ["No lost documents"], outcomeVision: "Passport valid for ten years",
                    brainstorm: ["Form DS-82", "Photo", "Fee"], nextActions: ["Find the current passport", "Take a photo", "Fill DS-82"],
                    contexts: ["@home", "@errands", "@computer"], minutes: [10, 20, 30])
    }
}
