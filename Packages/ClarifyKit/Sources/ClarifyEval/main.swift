import Foundation
import ClarifyKit

// clarify-eval --gold path.jsonl [--provider on-device|endpoint] [--url http://127.0.0.1:1234] [--model name] [--key k] [--limit n]
struct Gold: Decodable {
    var title: String
    var notes: String?
    var kind: String
    var context: String?
    var verbs: [String]?
    var delegated: String?
}

func arg(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let goldPath = arg("gold") ?? "Eval/gold/inbox.jsonl"
let provider = arg("provider") ?? "on-device"
let limit = arg("limit").flatMap(Int.init) ?? Int.max

let model: LanguageModel
switch provider {
case "endpoint":
    guard let url = URL(string: arg("url") ?? "http://127.0.0.1:1234"), let name = arg("model") else {
        FileHandle.standardError.write(Data("endpoint needs --model\n".utf8)); exit(2)
    }
    model = EndpointLanguageModel(baseURL: url, apiKey: arg("key"), model: name, timeout: 300)
default:
    if case .failure(let e) = FoundationLanguageModel.availability() { FileHandle.standardError.write(Data("\(e.localizedDescription)\n".utf8)); exit(2) }
    model = FoundationLanguageModel()
}

let lines = try String(contentsOfFile: goldPath, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
let gold = try lines.prefix(limit).map { try JSONDecoder().decode(Gold.self, from: Data($0.utf8)) }

struct NoContacts: ContactsBridge { func lookup(name: String) async throws -> [ContactMatch] { [] } }
struct NoFiles: FilesBridge { func find(query: String, limit: Int) async throws -> [URL] { [] } }
struct NoMail: MailBridge {
    func draft(to: String, subject: String, body: String, attachment: URL?) async throws {}
    func send(to: String, subject: String, body: String, attachment: URL?) async throws {}
    func inbox(since: Date) async throws -> [MailMessage] { [] }
}
struct NoMessages: MessagesBridge { func send(text: String, to handle: String) async throws {} }

let store = MemoryStore()
try await store.create(NewReminder(title: Clarifier.areasTitle, notes: "Area: Health\nArea: Admin\nArea: Home\nArea: Work\nArea: Family\nGoal: Ship Clarify", list: Bucket.reference.rawValue))
let services = Services(store: store, model: model, ledger: Ledger(url: nil), contacts: NoContacts(), files: NoFiles(), mail: NoMail(),
                        messages: NoMessages(), settings: Settings(), now: { DateOnly.parse("2026-09-12")! })
let clarifier = Clarifier(services)

struct Miss { var title: String; var field: String; var expected: String; var got: String }
var kindHits = 0, contextHits = 0, contextTotal = 0, verbHits = 0, verbTotal = 0, delegatedHits = 0, delegatedTotal = 0, invalid = 0
var misses: [Miss] = []
var latencies: [Double] = []
let started = Date()

for (i, g) in gold.enumerated() {
    let item = ReminderItem(id: "g\(i)", title: g.title, notes: g.notes, list: "Reminders")
    let t = Date()
    let decision: ClarifyDecision
    do {
        decision = try await clarifier.decide(item)
    } catch {
        invalid += 1
        misses.append(Miss(title: g.title, field: "error", expected: g.kind, got: error.localizedDescription))
        print("[\(i + 1)/\(gold.count)] ERROR \(g.title): \(error.localizedDescription)")
        continue
    }
    latencies.append(Date().timeIntervalSince(t))
    if decision.kind == g.kind { kindHits += 1 } else { misses.append(Miss(title: g.title, field: "kind", expected: g.kind, got: decision.kind)) }
    if let c = g.context {
        contextTotal += 1
        if decision.context == c { contextHits += 1 } else { misses.append(Miss(title: g.title, field: "context", expected: c, got: decision.context)) }
    }
    if let verbs = g.verbs {
        verbTotal += 1
        let first = decision.nextAction.lowercased().split(separator: " ").first.map(String.init) ?? ""
        if verbs.contains(where: { first.hasPrefix($0) }) { verbHits += 1 } else { misses.append(Miss(title: g.title, field: "verb", expected: verbs.joined(separator: "|"), got: decision.nextAction)) }
    }
    if let d = g.delegated {
        delegatedTotal += 1
        if decision.delegatedTo.localizedCaseInsensitiveContains(d) { delegatedHits += 1 } else { misses.append(Miss(title: g.title, field: "delegated", expected: d, got: decision.delegatedTo)) }
    }
    print("[\(i + 1)/\(gold.count)] \(decision.kind == g.kind ? "ok " : "MISS") \(g.title) -> \(decision.kind) \(decision.context) \"\(decision.nextAction)\" (\(Int(latencies.last! * 1000)) ms)")
}

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "n/a" : String(format: "%.0f%% (%d/%d)", Double(a) / Double(b) * 100, a, b) }
print("""

provider: \(model.name)
items: \(gold.count)   invalid outputs: \(invalid)
kind accuracy:      \(pct(kindHits, gold.count))
context accuracy:   \(pct(contextHits, contextTotal))
verb-first actions: \(pct(verbHits, verbTotal))
delegated named:    \(pct(delegatedHits, delegatedTotal))
median latency:     \(latencies.isEmpty ? 0 : Int(latencies.sorted()[latencies.count / 2] * 1000)) ms   total \(Int(Date().timeIntervalSince(started))) s
""")
if !misses.isEmpty {
    print("misses:")
    for m in misses { print("  \(m.field.padding(toLength: 9, withPad: " ", startingAt: 0)) \(m.title) | expected \(m.expected) | got \(m.got)") }
}
