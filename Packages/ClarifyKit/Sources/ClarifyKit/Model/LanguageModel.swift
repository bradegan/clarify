import Foundation
import FoundationModels

/// A typed output the model must produce. Each job has exactly one.
/// Generable drives on-device guided generation; Codable plus `jsonSchema`
/// drive the OpenAI-compatible endpoint; `validate` is the deterministic gate
/// both paths pass through before any side effect.
public protocol ClarifyOutput: Generable, Codable, Sendable {
    static var schemaName: String { get }
    static var jsonSchema: String { get }
    func validate() throws
}

public protocol LanguageModel: Sendable {
    var name: String { get }
    func respond<T: ClarifyOutput>(instructions: String, input: String, as type: T.Type) async throws -> T
}

public enum ModelError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case invalidOutput(String)
    case http(Int, String)
    case authFailed(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "Model unavailable: \(why)"
        case .invalidOutput(let why): return "Model output rejected: \(why)"
        case .http(let code, let body): return "Endpoint returned HTTP \(code): \(body)"
        case .authFailed(let body): return "Endpoint rejected credentials: \(body)"
        case .emptyResponse: return "Endpoint returned no content"
        }
    }
}

public enum ValidationError: Error, LocalizedError, Equatable {
    case notInSet(field: String, value: String, allowed: [String])
    case outOfRange(field: String, value: Int, range: ClosedRange<Int>)
    case empty(field: String)

    public var errorDescription: String? {
        switch self {
        case .notInSet(let f, let v, let a): return "\(f) is '\(v)', expected one of \(a.joined(separator: ", "))"
        case .outOfRange(let f, let v, let r): return "\(f) is \(v), expected \(r.lowerBound) to \(r.upperBound)"
        case .empty(let f): return "\(f) is empty"
        }
    }
}

func requireOneOf(_ value: String, _ allowed: [String], field: String) throws {
    guard allowed.contains(value) else { throw ValidationError.notInSet(field: field, value: value, allowed: allowed) }
}

func requireRange(_ value: Int, _ range: ClosedRange<Int>, field: String) throws {
    guard range.contains(value) else { throw ValidationError.outOfRange(field: field, value: value, range: range) }
}

func requireNonEmpty(_ value: String, field: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationError.empty(field: field) }
}
