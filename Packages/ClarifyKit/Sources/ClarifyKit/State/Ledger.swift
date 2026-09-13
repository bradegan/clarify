import Foundation

/// What Clarify will do when an Approve reminder is completed.
public enum PendingAction: Codable, Equatable, Sendable {
    case sendMail(to: String, subject: String, body: String, attachment: String?)
    case sendMessage(handle: String, text: String)
    case closeWaiting(reminderID: String, quote: String)
    case chooseAttachment(reminderID: String, path: String, to: String, subject: String, body: String)
    case answerQuestion(sourceID: String, question: String)
}

public struct LedgerEntry: Codable, Equatable, Sendable {
    public var hash: String
    public var processedAt: Date
    public var pending: PendingAction?
    public init(hash: String, processedAt: Date = Date(), pending: PendingAction? = nil) {
        self.hash = hash; self.processedAt = processedAt; self.pending = pending
    }
}

/// Append-only record of every reminder Clarify has looked at, keyed by the
/// reminder identifier. Persisted as JSON when a URL is given.
public actor Ledger {
    private var entries: [String: LedgerEntry]
    private let url: URL?

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.ledger.decode([String: LedgerEntry].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    public func entry(for id: String) -> LedgerEntry? { entries[id] }

    public func isProcessed(_ item: ReminderItem) -> Bool {
        entries[item.id]?.hash == item.contentHash
    }

    public func record(_ id: String, hash: String, pending: PendingAction? = nil) throws {
        entries[id] = LedgerEntry(hash: hash, pending: pending)
        try persist()
    }

    public func setPending(_ id: String, _ pending: PendingAction?) throws {
        guard var e = entries[id] else { return }
        e.pending = pending
        entries[id] = e
        try persist()
    }

    public var count: Int { entries.count }

    private func persist() throws {
        guard let url else { return }
        let data = try JSONEncoder.ledger.encode(entries)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var ledger: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}
extension JSONDecoder {
    static var ledger: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
