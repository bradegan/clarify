import Foundation
import FoundationModels

/// On-device Apple Foundation Models. One session per instruction set; the
/// session is replaced when the context window fills, since sessions accumulate
/// transcript and the window is 4,096 tokens.
public actor FoundationLanguageModel: LanguageModel {
    nonisolated public let name = "on-device"
    private var sessions: [String: LanguageModelSession] = [:]

    public init() {}

    public static func availability() -> Result<Void, ModelError> {
        switch SystemLanguageModel.default.availability {
        case .available: return .success(())
        case .unavailable(let reason): return .failure(.unavailable(FoundationLanguageModel.describe(reason)))
        }
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "this Mac does not support Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is off in System Settings"
        case .modelNotReady: return "the model is still downloading"
        @unknown default: return "unknown reason"
        }
    }

    public func respond<T: ClarifyOutput>(instructions: String, input: String, as type: T.Type) async throws -> T {
        if case .failure(let e) = FoundationLanguageModel.availability() { throw e }
        let session = sessions[instructions] ?? LanguageModelSession(instructions: instructions)
        sessions[instructions] = session
        do {
            return try await session.respond(to: input, generating: type).content
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            let fresh = LanguageModelSession(instructions: instructions)
            sessions[instructions] = fresh
            return try await fresh.respond(to: input, generating: type).content
        } catch let error as LanguageModelSession.GenerationError {
            throw ModelError.invalidOutput(String(describing: error))
        }
    }
}
