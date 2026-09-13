import Foundation

public struct ContactMatch: Equatable, Sendable {
    public var name: String
    public var phones: [String]
    public var emails: [String]
    public var addresses: [String]
    public init(name: String, phones: [String] = [], emails: [String] = [], addresses: [String] = []) {
        self.name = name; self.phones = phones; self.emails = emails; self.addresses = addresses
    }
}

public struct MailMessage: Equatable, Sendable {
    public var sender: String
    public var subject: String
    public var received: Date
    public var excerpt: String
    public init(sender: String, subject: String, received: Date, excerpt: String) {
        self.sender = sender; self.subject = subject; self.received = received; self.excerpt = excerpt
    }
}

public protocol ContactsBridge: Sendable {
    func lookup(name: String) async throws -> [ContactMatch]
}

public protocol FilesBridge: Sendable {
    /// Newest first.
    func find(query: String, limit: Int) async throws -> [URL]
}

public protocol MailBridge: Sendable {
    func draft(to: String, subject: String, body: String, attachment: URL?) async throws
    func send(to: String, subject: String, body: String, attachment: URL?) async throws
    func inbox(since: Date) async throws -> [MailMessage]
}

public protocol MessagesBridge: Sendable {
    func send(text: String, to handle: String) async throws
}

public enum BridgeError: Error, LocalizedError, Equatable {
    case scriptFailed(String)
    case notFound(String)
    public var errorDescription: String? {
        switch self {
        case .scriptFailed(let m): return "Apple Events failed: \(m)"
        case .notFound(let m): return m
        }
    }
}

public struct WebSource: Equatable, Sendable {
    public var title: String
    public var url: String
    public init(title: String, url: String) { self.title = title; self.url = url }
}

public struct WebAnswer: Equatable, Sendable {
    public var answer: String
    public var sources: [WebSource]
    public init(answer: String, sources: [WebSource]) { self.answer = answer; self.sources = sources }
}

/// Grounded web answer with citations. Backed by Exa.
public protocol WebSearchBridge: Sendable {
    func answer(_ query: String) async throws -> WebAnswer
}
