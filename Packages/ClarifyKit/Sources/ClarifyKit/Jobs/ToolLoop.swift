import Foundation

/// The agentic path for the two-minute rule. The model chains tools across
/// Contacts, Spotlight, Calendar, Reminders, Mail, and Messages until the task
/// is done, it needs the user, or it hits the step cap. Every send waits in Approve.
public struct ToolLoop: Sendable {
    let services: Services
    public static let maxSteps = 6
    public init(_ services: Services) { self.services = services }

    public struct Outcome: Sendable, Equatable {
        public var steps: [String]
        public var summary: String
        public var awaitingAnswer: Bool
    }

    public func run(item: ReminderItem, goal: String, priorAnswers: String = "") async throws -> Outcome {
        guard let model = services.toolModel else { throw ModelError.unavailable("no tool-calling model configured") }
        let tools = AgentTools.specs(contexts: services.settings.contexts, web: services.web != nil)
        let executor = AgentTools(services, source: item)
        let system = """
        You are a Getting Things Done assistant completing one small task for the user by calling tools.
        Today is \(DateOnly.string(services.now())).
        Chain tools as needed: look up people before you draft to them, find files before you attach them, \
        check the calendar before you propose a time. Use web_search for facts you do not have, such as a phone number or an address, and prefer the answer's sources. When the task is a call or an errand, look up the fact the user will need (a phone number, an address) and save_note it to the reminder so they have it. When you cannot prepare anything useful, reply with a short note and no tool call. Prepared emails and texts are not sent until the user \
        approves them, so draft them when ready. If you genuinely cannot proceed without a fact only the user \
        knows, call ask_user once and stop. When the task is prepared, reply with a one-sentence summary and \
        no tool call.
        """
        var messages: [ChatMessage] = [.init(role: .user, content:
            "Task: \(goal)\nReminder: \(item.title)\nNotes: \(item.body.isEmpty ? "(none)" : item.body)\(priorAnswers.isEmpty ? "" : "\nAnswered questions:\n\(priorAnswers)")")]
        var steps: [String] = []

        for _ in 0..<ToolLoop.maxSteps {
            let turn = try await model.converse(system: system, messages: messages, tools: tools)
            guard !turn.toolCalls.isEmpty else {
                let summary = turn.text.isEmpty ? "Prepared." : turn.text
                services.log("Agent: \(summary)")
                return Outcome(steps: steps, summary: summary, awaitingAnswer: false)
            }
            messages.append(.init(role: .assistant, content: turn.text, toolCalls: turn.toolCalls))
            for call in turn.toolCalls {
                let result = (try? await executor.run(call)) ?? "{\"error\":\"tool failed\"}"
                let note = ToolLoop.describe(call)
                steps.append(note)
                services.log("Agent step: \(note)")
                messages.append(.init(role: .tool, content: String(result.prefix(1500)), toolCallID: call.id))
            }
            if executor.state.awaitingAnswer {
                return Outcome(steps: steps, summary: "Waiting for your answer.", awaitingAnswer: true)
            }
        }
        services.log("Agent: reached the step limit")
        return Outcome(steps: steps, summary: "Stopped at the step limit; see Approve for anything prepared.", awaitingAnswer: false)
    }

    static func describe(_ call: ToolInvocation) -> String {
        switch call.name {
        case "lookup_contact": return "looked up \(call.arg("name") ?? "a contact")"
        case "find_file": return "searched files for '\(call.arg("query") ?? "")'"
        case "search_calendar": return "checked the calendar on \(call.arg("date") ?? "")"
        case "read_reminders": return "searched reminders for '\(call.arg("query") ?? "")'"
        case "read_mail": return "searched mail for '\(call.arg("query") ?? "")'"
        case "draft_email": return "drafted an email to \(call.arg("to") ?? "")"
        case "draft_text": return "drafted a text to \(call.arg("phone") ?? "")"
        case "create_event": return "created an event '\(call.arg("title") ?? "")'"
        case "web_search": return "searched the web for '\(call.arg("query") ?? "")'"
        case "save_note": return "saved a note to the reminder"
        case "ask_user": return "asked: \(call.arg("question") ?? "")"
        default: return "called \(call.name)"
        }
    }
}
