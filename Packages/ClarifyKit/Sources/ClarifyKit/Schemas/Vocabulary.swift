import Foundation

public enum Kind: String, CaseIterable, Sendable {
    case trash, reference, someday, calendar, waiting, action, project
    public static let allValues = allCases.map(\.rawValue)
}

public enum Energy: String, CaseIterable, Sendable {
    case low, medium, high
    public static let allValues = allCases.map(\.rawValue)
    var rank: Int { Energy.allCases.firstIndex(of: self)! }
}

public enum Recipe: String, CaseIterable, Sendable {
    case none
    case emailWithAttachment = "email_with_attachment"
    case message
    case calendarEvent = "calendar_event"
    case contactLookup = "contact_lookup"
    case fileLookup = "file_lookup"
    public static let allValues = allCases.map(\.rawValue)
}

public enum Contexts {
    public static let defaults = ["@computer", "@phone", "@home", "@errands", "@anywhere", "@agenda"]
}
