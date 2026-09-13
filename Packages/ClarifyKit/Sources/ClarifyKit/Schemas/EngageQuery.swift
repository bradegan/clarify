import Foundation
import FoundationModels

@Generable
public struct EngageQuery: ClarifyOutput {
    @Guide(description: "A context from the vocabulary, or empty for any")
    public var context: String
    @Guide(description: "Minutes available, 0 for no limit", .range(0...480))
    public var minutes: Int
    @Guide(description: "low, medium, high, or empty for any", .anyOf(["low", "medium", "high", ""]))
    public var energy: String

    public init(context: String, minutes: Int, energy: String) { self.context = context; self.minutes = minutes; self.energy = energy }

    public static let schemaName = "engage_query"
    public static let jsonSchema = """
    {"type":"object","additionalProperties":false,"required":["context","minutes","energy"],
     "properties":{"context":{"type":"string"},"minutes":{"type":"integer","minimum":0,"maximum":480},
      "energy":{"type":"string","enum":["low","medium","high",""]}}}
    """
    public func validate() throws {
        try requireRange(minutes, 0...480, field: "minutes")
        if !energy.isEmpty { try requireOneOf(energy, Energy.allValues, field: "energy") }
    }
}
