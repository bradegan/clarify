import Foundation
import ClarifyKit

/// How the app was launched. UI tests pass `-uiTest` to get an in-memory store
/// and a deterministic model, so the real Reminders store is never touched.
struct Configuration {
    var uiTest: Bool
    var supportDirectory: URL

    static func fromProcess() -> Configuration {
        let args = ProcessInfo.processInfo.arguments
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clarify")
        return Configuration(uiTest: args.contains("-uiTest"), supportDirectory: base)
    }

    var settingsURL: URL { supportDirectory.appendingPathComponent("settings.json") }
    var ledgerURL: URL? { uiTest ? nil : supportDirectory.appendingPathComponent("ledger.json") }
}
