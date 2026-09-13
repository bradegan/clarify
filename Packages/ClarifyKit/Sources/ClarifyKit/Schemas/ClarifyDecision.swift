import Foundation
import FoundationModels

/// Output of the clarify job. One per inbox item.
@Generable
public struct ClarifyDecision: ClarifyOutput {
    @Guide(description: "True when the item requires any action from the user")
    public var actionable: Bool
    @Guide(description: "trash, reference, someday, calendar, waiting, action, or project", .anyOf(["trash", "reference", "someday", "calendar", "waiting", "action", "project"]))
    public var kind: String
    @Guide(description: "The desired outcome in one line")
    public var outcome: String
    @Guide(description: "The very next physical action, starting with a verb, one line")
    public var nextAction: String
    @Guide(description: "A context from the vocabulary, for example @phone. Use @anywhere when unsure")
    public var context: String
    @Guide(description: "Minutes the next action takes", .range(1...480))
    public var minutes: Int
    @Guide(description: "low, medium, or high", .anyOf(["low", "medium", "high"]))
    public var energy: String
    @Guide(description: "An area of responsibility from the list given, or Unsorted")
    public var area: String
    @Guide(description: "ISO 8601 date or datetime for calendar items, otherwise empty")
    public var date: String
    @Guide(description: "Person the item is delegated to or waited on, otherwise empty")
    public var delegatedTo: String
    @Guide(description: "none, email_with_attachment, message, calendar_event, contact_lookup, or file_lookup", .anyOf(["none", "email_with_attachment", "message", "calendar_event", "contact_lookup", "file_lookup"]))
    public var recipe: String
    @Guide(description: "One line explaining the decision")
    public var reason: String
    @Guide(description: "True when preparing the next action means looking someone up, finding a file, checking the calendar, drafting a message, or searching the web for a fact")
    public var needsPrep: Bool

    public init(actionable: Bool, kind: String, outcome: String, nextAction: String, context: String, minutes: Int, energy: String,
                area: String, date: String, delegatedTo: String, recipe: String, reason: String, needsPrep: Bool = false) {
        self.actionable = actionable; self.kind = kind; self.outcome = outcome; self.nextAction = nextAction; self.context = context
        self.minutes = minutes; self.energy = energy; self.area = area; self.date = date; self.delegatedTo = delegatedTo
        self.recipe = recipe; self.reason = reason; self.needsPrep = needsPrep
    }

    public static let schemaName = "clarify_decision"
    public static let jsonSchema = """
    {"type":"object","additionalProperties":false,
     "required":["actionable","kind","outcome","nextAction","context","minutes","energy","area","date","delegatedTo","recipe","reason","needsPrep"],
     "properties":{
      "actionable":{"type":"boolean"},
      "kind":{"type":"string","enum":["trash","reference","someday","calendar","waiting","action","project"]},
      "outcome":{"type":"string"},
      "nextAction":{"type":"string"},
      "context":{"type":"string"},
      "minutes":{"type":"integer","minimum":1,"maximum":480},
      "energy":{"type":"string","enum":["low","medium","high"]},
      "area":{"type":"string"},
      "date":{"type":"string"},
      "delegatedTo":{"type":"string"},
      "recipe":{"type":"string","enum":["none","email_with_attachment","message","calendar_event","contact_lookup","file_lookup"]},
      "reason":{"type":"string"},
      "needsPrep":{"type":"boolean"}}}
    """

    public func validate() throws {
        try requireOneOf(kind, Kind.allValues, field: "kind")
        try requireOneOf(energy, Energy.allValues, field: "energy")
        try requireOneOf(recipe, Recipe.allValues, field: "recipe")
        try requireRange(minutes, 1...480, field: "minutes")
        try requireNonEmpty(reason, field: "reason")
        if kind == Kind.action.rawValue || kind == Kind.project.rawValue {
            try requireNonEmpty(nextAction, field: "nextAction")
        }
        if kind == Kind.calendar.rawValue {
            try requireNonEmpty(date, field: "date")
            guard ISO8601.parse(date) != nil else { throw ValidationError.notInSet(field: "date", value: date, allowed: ["ISO 8601 date or datetime"]) }
        }
    }

    public var kindValue: Kind { Kind(rawValue: kind) ?? .action }
    public var energyValue: Energy { Energy(rawValue: energy) ?? .medium }
    public var recipeValue: Recipe { Recipe(rawValue: recipe) ?? .none }
}

public enum ISO8601 {
    /// Accepts `2026-10-03`, `2026-10-03T14:00`, and `2026-10-03T14:00:00Z` style values.
    public static func parse(_ text: String) -> (date: Date, hasTime: Bool)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: trimmed) { return (d, true) }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for (fmt, hasTime) in [("yyyy-MM-dd'T'HH:mm:ss", true), ("yyyy-MM-dd'T'HH:mm", true), ("yyyy-MM-dd HH:mm", true), ("yyyy-MM-dd", false)] {
            local.dateFormat = fmt
            if let d = local.date(from: trimmed) { return (d, hasTime) }
        }
        return nil
    }
}
