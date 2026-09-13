import Foundation
import FoundationModels

/// David Allen's natural planning model, one struct.
@Generable
public struct ProjectPlan: ClarifyOutput {
    @Guide(description: "Why this project matters, one or two sentences")
    public var purpose: String
    @Guide(description: "Standards or constraints to hold, up to five short lines", .count(1...5))
    public var principles: [String]
    @Guide(description: "What done looks like, one paragraph")
    public var outcomeVision: String
    @Guide(description: "Ideas, questions, and pieces, up to twelve short lines", .count(1...12))
    public var brainstorm: [String]
    @Guide(description: "Exactly three next physical actions, each starting with a verb", .count(3))
    public var nextActions: [String]
    @Guide(description: "A context for each next action, same order", .count(3))
    public var contexts: [String]
    @Guide(description: "Minutes for each next action, same order", .count(3))
    public var minutes: [Int]

    public init(purpose: String, principles: [String], outcomeVision: String, brainstorm: [String], nextActions: [String], contexts: [String], minutes: [Int]) {
        self.purpose = purpose; self.principles = principles; self.outcomeVision = outcomeVision; self.brainstorm = brainstorm
        self.nextActions = nextActions; self.contexts = contexts; self.minutes = minutes
    }

    public static let schemaName = "project_plan"
    public static let jsonSchema = """
    {"type":"object","additionalProperties":false,
     "required":["purpose","principles","outcomeVision","brainstorm","nextActions","contexts","minutes"],
     "properties":{"purpose":{"type":"string"},"principles":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":5},
      "outcomeVision":{"type":"string"},"brainstorm":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":12},
      "nextActions":{"type":"array","items":{"type":"string"},"minItems":3,"maxItems":3},
      "contexts":{"type":"array","items":{"type":"string"},"minItems":3,"maxItems":3},
      "minutes":{"type":"array","items":{"type":"integer","minimum":1,"maximum":480},"minItems":3,"maxItems":3}}}
    """

    /// Models sometimes pack the context and minutes into the action text
    /// ("Call the post office from @phone 10"). Strip those so titles stay clean.
    public var cleanedNextActions: [String] {
        nextActions.map { ProjectPlan.clean($0) }
    }

    static func clean(_ action: String) -> String {
        let dangling: Set<String> = ["on", "at", "from", "in", "via", "using", "with", "for", "the"]
        var words = action.split(separator: " ").map(String.init)
            .filter { !$0.hasPrefix("@") && Int($0.trimmingCharacters(in: .punctuationCharacters)) == nil }
        while let last = words.last, dangling.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) { words.removeLast() }
        return words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    public func validate() throws {
        guard nextActions.count == 3, contexts.count == 3, minutes.count == 3 else {
            throw ValidationError.outOfRange(field: "nextActions", value: nextActions.count, range: 3...3)
        }
        for (i, action) in cleanedNextActions.enumerated() {
            try requireNonEmpty(action, field: "nextActions[\(i)]")
            try requireRange(minutes[i], 1...480, field: "minutes[\(i)]")
        }
        try requireNonEmpty(purpose, field: "purpose")
    }
}
