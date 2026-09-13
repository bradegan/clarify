import Foundation

/// Apple Mail through Apple Events. Drafts are visible so the user can read
/// and edit them. Sending prefers the open draft with the same subject so the
/// user's edits survive; otherwise it builds and sends a fresh message.
public struct MailApp: MailBridge {
    public init() {}

    public func draft(to: String, subject: String, body: String, attachment: URL?) async throws {
        try await AppleScript.run(MailApp.compose(to: to, subject: subject, body: body, attachment: attachment, visible: true, send: false))
    }

    public func send(to: String, subject: String, body: String, attachment: URL?) async throws {
        let existing = """
        tell application "Mail"
            set found to (every outgoing message whose subject is \(AppleScript.quoted(subject)))
            if (count of found) > 0 then
                send (item 1 of found)
                return "sent-existing"
            end if
            return "none"
        end tell
        """
        if try await AppleScript.run(existing) == "sent-existing" { return }
        try await AppleScript.run(MailApp.compose(to: to, subject: subject, body: body, attachment: attachment, visible: false, send: true))
    }

    public func inbox(since: Date) async throws -> [MailMessage] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        let script = """
        set sinceDate to date "\(f.string(from: since))"
        set outLines to {}
        tell application "Mail"
            set msgs to (every message of inbox whose date received > sinceDate)
            repeat with m in msgs
                set snippet to text 1 thru (min(500, length of (content of m))) of (content of m)
                set end of outLines to (sender of m) & tab & (subject of m) & tab & ((date received of m) as «class isot» as string) & tab & snippet
            end repeat
        end tell
        set AppleScript's text item delimiters to (ASCII character 30)
        return outLines as text
        """
        let raw = try await AppleScript.run(script)
        guard !raw.isEmpty else { return [] }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return raw.split(separator: "\u{1E}").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { return nil }
            return MailMessage(sender: parts[0], subject: parts[1], received: iso.date(from: parts[2]) ?? since,
                               excerpt: parts[3].replacingOccurrences(of: "\r", with: "\n"))
        }
    }

    static func compose(to: String, subject: String, body: String, attachment: URL?, visible: Bool, send: Bool) -> String {
        var lines = [
            "tell application \"Mail\"",
            "set msg to make new outgoing message with properties {subject:\(AppleScript.quoted(subject)), content:\(AppleScript.quoted(body + "\n\n")), visible:\(visible)}",
            "tell msg",
            "make new to recipient at end of to recipients with properties {address:\(AppleScript.quoted(to))}",
        ]
        if let attachment {
            lines.append("make new attachment with properties {file name:POSIX file \(AppleScript.quoted(attachment.path))} at after the last paragraph of content")
        }
        lines.append("end tell")
        if send { lines.append("delay 1"); lines.append("send msg") }
        lines.append("end tell")
        return lines.joined(separator: "\n")
    }
}
