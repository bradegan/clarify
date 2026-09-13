import Foundation
import FoundationModels

/// Slots for the closed recipe set. Unused slots are empty strings so one
/// schema serves every recipe and the on-device model never sees optionals.
@Generable
public struct RecipeSlots: ClarifyOutput {
    @Guide(description: "Full or first name of the person, or empty")
    public var recipientName: String
    @Guide(description: "Email subject, or empty")
    public var subject: String
    @Guide(description: "Email or message body, or empty")
    public var body: String
    @Guide(description: "Words to find the file by, or empty")
    public var attachmentQuery: String
    @Guide(description: "Event title, or empty")
    public var eventTitle: String
    @Guide(description: "ISO 8601 start, or empty")
    public var start: String
    @Guide(description: "ISO 8601 end, or empty")
    public var end: String
    @Guide(description: "Contact field wanted: phone, email, address, or empty")
    public var contactField: String

    public init(recipientName: String, subject: String, body: String, attachmentQuery: String, eventTitle: String, start: String, end: String, contactField: String) {
        self.recipientName = recipientName; self.subject = subject; self.body = body; self.attachmentQuery = attachmentQuery
        self.eventTitle = eventTitle; self.start = start; self.end = end; self.contactField = contactField
    }

    public static let schemaName = "recipe_slots"
    public static let jsonSchema = """
    {"type":"object","additionalProperties":false,
     "required":["recipientName","subject","body","attachmentQuery","eventTitle","start","end","contactField"],
     "properties":{"recipientName":{"type":"string"},"subject":{"type":"string"},"body":{"type":"string"},
      "attachmentQuery":{"type":"string"},"eventTitle":{"type":"string"},"start":{"type":"string"},"end":{"type":"string"},
      "contactField":{"type":"string"}}}
    """

    public func validate() throws {}

    func validate(for recipe: Recipe) throws {
        switch recipe {
        case .emailWithAttachment:
            try requireNonEmpty(recipientName, field: "recipientName")
            try requireNonEmpty(subject, field: "subject")
            try requireNonEmpty(attachmentQuery, field: "attachmentQuery")
        case .message:
            try requireNonEmpty(recipientName, field: "recipientName")
            try requireNonEmpty(body, field: "body")
        case .calendarEvent:
            try requireNonEmpty(eventTitle, field: "eventTitle")
            guard ISO8601.parse(start) != nil else { throw ValidationError.notInSet(field: "start", value: start, allowed: ["ISO 8601"]) }
        case .contactLookup:
            try requireNonEmpty(recipientName, field: "recipientName")
        case .fileLookup:
            try requireNonEmpty(attachmentQuery, field: "attachmentQuery")
        case .none:
            break
        }
    }
}
