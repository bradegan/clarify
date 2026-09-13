import Foundation
import FoundationModels

@Generable
public struct WatcherVerdict: ClarifyOutput {
    @Guide(description: "True when this email resolves what the user was waiting for")
    public var closes: Bool
    @Guide(description: "A short verbatim quote from the email that shows it, or empty")
    public var quote: String
    @Guide(description: "One line reason")
    public var reason: String

    public init(closes: Bool, quote: String, reason: String) { self.closes = closes; self.quote = quote; self.reason = reason }

    public static let schemaName = "watcher_verdict"
    public static let jsonSchema = """
    {"type":"object","additionalProperties":false,"required":["closes","quote","reason"],
     "properties":{"closes":{"type":"boolean"},"quote":{"type":"string"},"reason":{"type":"string"}}}
    """
    public func validate() throws { try requireNonEmpty(reason, field: "reason") }
}
