import Foundation

/// Runs an AppleScript through osascript and returns its result. Errors carry
/// osascript's message so a missing Automation grant is visible in the log.
enum AppleScript {
    @discardableResult
    static func run(_ source: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
            process.terminationHandler = { p in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    cont.resume(returning: out.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    cont.resume(throwing: BridgeError.scriptFailed(err.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(source.utf8))
                try stdin.fileHandleForWriting.close()
            } catch {
                cont.resume(throwing: BridgeError.scriptFailed(error.localizedDescription))
            }
        }
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
