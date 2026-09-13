import Foundation

public struct LogLine: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let at: Date
    public let text: String
    public init(_ text: String, at: Date = Date()) { id = UUID(); self.at = at; self.text = text }
}

/// Small in-memory event log the menu bar shows. Callers get a closure so the
/// kit stays free of UI concerns.
public typealias Logger = @Sendable (String) -> Void
public let silentLogger: Logger = { _ in }
