import Foundation
import ClarifyKit

/// Data and a deterministic model for UI tests. The real Reminders store is
/// never touched when the app runs with `-uiTest`.
enum UITestSeed {
    static func populate(_ store: MemoryStore) {
        let items: [(String, String, Int, String)] = [
            ("@phone Call Dr. Patel to book a cleaning", "@phone", 5, "low"),
            ("@computer Write the hackathon README", "@computer", 60, "high"),
            ("@anywhere Stretch for five minutes", "@anywhere", 5, "low"),
            ("@phone Call the plumber about the leak", "@phone", 15, "medium"),
        ]
        Task {
            for (title, context, minutes, energy) in items {
                _ = try await store.create(NewReminder(title: title, notes: Header(["kind": "action", "context": context, "minutes": String(minutes), "energy": energy, "since": "2026-09-01"]).render(body: ""), list: Bucket.nextActions.rawValue))
            }
        }
    }
}

/// Keyword parser standing in for the language model under UI tests.
struct UITestModel: LanguageModel {
    let name = "ui-test"
    func respond<T: ClarifyOutput>(instructions: String, input: String, as type: T.Type) async throws -> T {
        guard type == EngageQuery.self else { throw ModelError.unavailable("ui test model only answers engage queries") }
        let text = (input.split(separator: "\n").first { $0.hasPrefix("Request:") } ?? "").lowercased()
        let context = Contexts.defaults.first { text.contains($0) } ?? ""
        let minutes = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first ?? 0
        let energy = Energy.allCases.first { text.contains($0.rawValue) }?.rawValue ?? ""
        return EngageQuery(context: context, minutes: minutes, energy: energy) as! T
    }
}
