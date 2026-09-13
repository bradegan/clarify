import Foundation

/// Actions the app accepts through its `clarify://` URL scheme, so Shortcuts,
/// scripts, and the demo can trigger work without the popover.
public enum RemoteCommand: Equatable, Sendable {
    case process
    case processExisting
    case weeklyReview
    case dailySweep
    case checkMail
    case engage(String)

    public static let scheme = "clarify"

    public static func parse(_ url: URL) -> RemoteCommand? {
        guard url.scheme == scheme else { return nil }
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" }).filter { !$0.isEmpty }.joined(separator: "/")
        switch path {
        case "process": return .process
        case "process/existing": return .processExisting
        case "review/weekly": return .weeklyReview
        case "sweep/daily": return .dailySweep
        case "mail/check": return .checkMail
        case "engage":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            return .engage(q)
        default: return nil
        }
    }
}
