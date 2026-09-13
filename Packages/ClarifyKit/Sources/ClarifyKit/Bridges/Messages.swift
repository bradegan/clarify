import Foundation

/// Messages through Apple Events, using the `send ... to participant` form
/// from the macOS 26 scripting dictionary.
public struct MessagesApp: MessagesBridge {
    public init() {}

    public func send(text: String, to handle: String) async throws {
        let script = """
        tell application "Messages"
            set targetService to first account whose enabled is true
            set target to participant \(AppleScript.quoted(handle)) of targetService
            send \(AppleScript.quoted(text)) to target
        end tell
        """
        try await AppleScript.run(script)
    }
}
