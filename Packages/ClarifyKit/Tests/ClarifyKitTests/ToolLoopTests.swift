import XCTest
@testable import ClarifyKit

final class ToolLoopTests: XCTestCase {
    func item(_ h: Harness, _ title: String, notes: String = "") -> ReminderItem {
        ReminderItem(id: "src-1", title: title, notes: Header(["kind": "action"]).render(body: notes), list: "Next Actions")
    }

    func testChainsContactLookupThenTextDraftAcrossApps() async throws {
        var h = Harness(); h.useToolModel = true
        h.contacts.people = [ContactMatch(name: "Sam Rivera", phones: ["+16105551212"])]
        h.toolModel.turns = [
            AssistantTurn(text: "", toolCalls: [toolCall("lookup_contact", ["name": "Sam"])]),
            AssistantTurn(text: "", toolCalls: [toolCall("draft_text", ["phone": "+16105551212", "body": "Running ten minutes late"])]),
            AssistantTurn(text: "Text to Sam is ready for your approval.", toolCalls: []),
        ]
        let src = item(h, "@phone Text Sam I'm running late")
        try await h.store.save(try await h.store.create(NewReminder(title: src.title, notes: src.notes, list: "Next Actions")))
        let outcome = try await ToolLoop(h.services()).run(item: src, goal: "Text Sam I'm running late")
        XCTAssertFalse(outcome.awaitingAnswer)
        XCTAssertEqual(outcome.steps, ["looked up Sam", "drafted a text to +16105551212"])
        let approvals = try await h.store.reminders(in: "Approve", includeCompleted: false)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertTrue(h.messages.sent.isEmpty, "nothing sends without approval")
        // The second conversation turn must include the tool result the model chained on.
        let toolResults = h.toolModel.conversations.last!.filter { $0.role == .tool }
        XCTAssertTrue(toolResults.contains { $0.content.contains("+16105551212") })
    }

    func testAskUserHaltsAndFilesAQuestion() async throws {
        var h = Harness(); h.useToolModel = true
        h.toolModel.turns = [AssistantTurn(text: "", toolCalls: [toolCall("ask_user", ["question": "Which Sam, Rivera or Cole?"])])]
        let outcome = try await ToolLoop(h.services()).run(item: item(h, "Text Sam"), goal: "Text Sam")
        XCTAssertTrue(outcome.awaitingAnswer)
        let questions = try await h.store.reminders(in: "Approve", includeCompleted: false)
        XCTAssertEqual(questions.count, 1)
        XCTAssertTrue(questions[0].title.contains("Which Sam"))
        XCTAssertEqual(questions[0].header?["kind"], "question")
    }

    func testAnsweringAQuestionResumesTheLoopWithTheAnswer() async throws {
        var h = Harness(); h.useToolModel = true
        h.contacts.people = [ContactMatch(name: "Sam Cole", phones: ["+16105550000"])]
        let src = try await h.store.create(NewReminder(title: "@phone Text Sam", notes: Header(["kind": "action"]).render(body: ""), list: "Next Actions"))
        // A question was filed for that source; the user typed the answer in its notes and completed it.
        var q = try await h.store.create(NewReminder(title: "Answer for 'Text Sam': Which Sam?",
            notes: Header(["kind": "question", "for": src.id]).render(body: "Sam Cole"), list: "Approve"))
        try await h.ledger.record(q.id, hash: q.contentHash, pending: .answerQuestion(sourceID: src.id, question: "Which Sam?"))
        q.isCompleted = true; try await h.store.save(q)
        h.toolModel.turns = [
            AssistantTurn(text: "", toolCalls: [toolCall("draft_text", ["phone": "+16105550000", "body": "On my way"])]),
            AssistantTurn(text: "Ready to send.", toolCalls: []),
        ]
        try await Recipes(h.services()).approve(q)
        let approvals = try await h.store.reminders(in: "Approve", includeCompleted: false)
        let approvalCount = approvals.count
        XCTAssertEqual(approvalCount, 1, "resuming drafts the text")
        // The resumed run must have carried the user's answer.
        XCTAssertTrue(h.toolModel.conversations.first!.first!.content.contains("Sam Cole"))
    }

    func testMutatingToolWithoutARealAddressReturnsAnErrorInsteadOfActing() async throws {
        var h = Harness(); h.useToolModel = true
        h.toolModel.turns = [
            AssistantTurn(text: "", toolCalls: [toolCall("draft_email", ["to": "Sam", "subject": "x", "body": "y"])]),
            AssistantTurn(text: "I need an address first.", toolCalls: []),
        ]
        _ = try await ToolLoop(h.services()).run(item: item(h, "email Sam"), goal: "email Sam")
        XCTAssertTrue(h.mail.drafts.isEmpty)
        let approveCount = try await h.store.reminders(in: "Approve", includeCompleted: false).count
        XCTAssertEqual(approveCount, 0)
    }

    func testWebSearchIsOfferedOnlyWhenConfiguredAndFeedsTheChain() async throws {
        var h = Harness(); h.useToolModel = true; h.useWeb = true
        h.web.result = WebAnswer(answer: "Call 877-487-2778 to book a passport appointment.",
                                 sources: [WebSource(title: "State Dept", url: "https://travel.state.gov")])
        h.toolModel.turns = [
            AssistantTurn(text: "", toolCalls: [toolCall("web_search", ["query": "passport appointment phone number"])]),
            AssistantTurn(text: "The passport appointment line is 877-487-2778.", toolCalls: []),
        ]
        let outcome = try await ToolLoop(h.services()).run(item: item(h, "find the passport appointment number"), goal: "find the number")
        XCTAssertEqual(h.web.queries.count, 1)
        XCTAssertTrue(outcome.steps.contains { $0.contains("searched the web") })
        let toolResults = h.toolModel.conversations.last!.filter { $0.role == .tool }
        XCTAssertTrue(toolResults.contains { $0.content.contains("877-487-2778") }, "the answer must reach the model")

        // Without web configured, the tool is not offered.
        var h2 = Harness(); h2.useToolModel = true; h2.useWeb = false
        h2.toolModel.turns = [AssistantTurn(text: "done", toolCalls: [])]
        _ = try await ToolLoop(h2.services()).run(item: item(h2, "x"), goal: "x")
        let offered = AgentTools.specs(contexts: Contexts.defaults, web: false).map(\.name)
        XCTAssertFalse(offered.contains("web_search"))
        XCTAssertTrue(AgentTools.specs(contexts: Contexts.defaults, web: true).map(\.name).contains("web_search"))
    }

    func testStopsAtStepLimit() async throws {
        var h = Harness(); h.useToolModel = true
        h.toolModel.turns = Array(repeating: AssistantTurn(text: "", toolCalls: [toolCall("read_reminders", ["query": "x"])]), count: 20)
        let outcome = try await ToolLoop(h.services()).run(item: item(h, "loop"), goal: "loop")
        XCTAssertEqual(outcome.steps.count, ToolLoop.maxSteps)
        XCTAssertFalse(outcome.awaitingAnswer)
    }
}
