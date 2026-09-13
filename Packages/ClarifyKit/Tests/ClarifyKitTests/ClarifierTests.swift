import XCTest
@testable import ClarifyKit

final class ClarifierTests: XCTestCase {
    func testActionMovesToNextActionsWithContextPrefixAndHeader() async throws {
        let h = Harness()
        let item = try await h.inbox("dentist", notes: "Dr. Patel")
        h.model.decisions = [.make(kind: .action, nextAction: "Call Dr. Patel to book a cleaning", context: "@phone", minutes: 5, recipe: .none)]
        try await Clarifier(h.services()).processInbox()
        let saved = try await h.store.reminder(id: item.id)!
        XCTAssertEqual(saved.list, "Next Actions")
        XCTAssertEqual(saved.title, "@phone Call Dr. Patel to book a cleaning")
        XCTAssertEqual(saved.header?["context"], "@phone")
        XCTAssertEqual(saved.header?["minutes"], "5")
        XCTAssertEqual(saved.header?["reason"], "because")
        XCTAssertEqual(saved.body, "Dr. Patel")
        let v16 = await h.ledger.isProcessed(saved)
        XCTAssertTrue(v16)
    }

    func testTrashReferenceSomedayMoveToTheirLists() async throws {
        let h = Harness()
        let a = try await h.inbox("old flyer"), b = try await h.inbox("wifi password 1234"), c = try await h.inbox("learn the serve")
        h.model.decisions = [.make(kind: .trash), .make(kind: .reference), .make(kind: .someday)]
        try await Clarifier(h.services()).processInbox()
        let v25 = try await h.store.reminder(id: a.id)?.list
        XCTAssertEqual(v25, "Trash")
        let v27 = try await h.store.reminder(id: b.id)?.list
        XCTAssertEqual(v27, "Reference")
        let v29 = try await h.store.reminder(id: c.id)?.list
        XCTAssertEqual(v29, "Someday/Maybe")
        let v31 = try await h.store.reminders(in: "Reminders", includeCompleted: false).count
        XCTAssertEqual(v31, 0)
    }

    func testCalendarCreatesEventCompletesItemAndAddsNextAction() async throws {
        let h = Harness()
        let item = try await h.inbox("mom's birthday Oct 3")
        h.model.decisions = [.make(kind: .calendar, nextAction: "Order flowers for mom", date: "2026-10-03")]
        try await Clarifier(h.services()).processInbox()
        XCTAssertEqual(h.store.events.count, 1)
        XCTAssertTrue(h.store.events[0].allDay)
        XCTAssertEqual(h.store.events[0].title, "mom's birthday Oct 3")
        let v43 = try await h.store.reminder(id: item.id)!.isCompleted
        XCTAssertTrue(v43)
        let actions = try await h.store.reminders(in: "Next Actions", includeCompleted: false)
        XCTAssertEqual(actions.map(\.title), ["@computer Order flowers for mom"])
    }

    func testCalendarWithTimeMakesTimedEvent() async throws {
        let h = Harness()
        try await h.inbox("standup")
        h.model.decisions = [.make(kind: .calendar, nextAction: "", date: "2026-09-14T10:00")]
        try await Clarifier(h.services()).processInbox()
        XCTAssertFalse(h.store.events[0].allDay)
        XCTAssertEqual(h.store.events[0].end.timeIntervalSince(h.store.events[0].start), 3600)
        let v56 = try await h.store.reminders(in: "Next Actions", includeCompleted: false).count
        XCTAssertEqual(v56, 0)
    }

    func testWaitingRecordsDelegate() async throws {
        let h = Harness()
        let item = try await h.inbox("lease from Jordan")
        h.model.decisions = [.make(kind: .waiting, delegatedTo: "Jordan")]
        try await Clarifier(h.services()).processInbox()
        let saved = try await h.store.reminder(id: item.id)!
        XCTAssertEqual(saved.list, "Waiting For")
        XCTAssertEqual(saved.header?["delegated_to"], "Jordan")
        XCTAssertEqual(saved.header?["since"], DateOnly.string(h.now))
    }

    func testProjectGetsPlanAndFirstNextAction() async throws {
        let h = Harness()
        let item = try await h.inbox("renew passport")
        h.model.decisions = [.make(kind: .project, nextAction: "Find passport", outcome: "Valid passport in hand")]
        h.model.plans = [.sample()]
        try await Clarifier(h.services()).processInbox()
        let project = try await h.store.reminder(id: item.id)!
        XCTAssertEqual(project.list, "Projects")
        XCTAssertEqual(project.title, "Valid passport in hand")
        XCTAssertTrue(project.body.contains("Purpose"))
        XCTAssertTrue(project.body.contains("Form DS-82"))
        let actions = try await h.store.reminders(in: "Next Actions", includeCompleted: false)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].title, "@home Find the current passport")
        XCTAssertEqual(actions[0].header?["project"], "Valid passport in hand")
    }

    func testPlanActionsAreStrippedOfPackedContextAndMinutes() async throws {
        XCTAssertEqual(ProjectPlan.clean("Check passport expiration on @computer 10"), "Check passport expiration")
        XCTAssertEqual(ProjectPlan.clean("Call the post office from @phone 10"), "Call the post office")
        XCTAssertEqual(ProjectPlan.clean("Gather birth certificate at @home 5."), "Gather birth certificate")
        XCTAssertEqual(ProjectPlan.clean("Book 2 courts"), "Book courts")
        var plan = ProjectPlan.sample(); plan.nextActions[0] = "10"
        XCTAssertThrowsError(try plan.validate(), "an action that is only a number is rejected before anything is saved")
        let h = Harness()
        let item = try await h.inbox("renew passport")
        h.model.decisions = [.make(kind: .project, nextAction: "Find passport", outcome: "Valid passport in hand")]
        var packed = ProjectPlan.sample(); packed.nextActions[0] = "Find the current passport at @home 10"
        h.model.plans = [packed]
        try await Clarifier(h.services()).processInbox()
        let actions = try await h.store.reminders(in: "Next Actions", includeCompleted: false)
        XCTAssertEqual(actions.map(\.title), ["@home Find the current passport"])
        _ = item
    }

    func testProcessedItemsAreNotReprocessedUntilEdited() async throws {
        let h = Harness()
        let item = try await h.inbox("dentist")
        h.model.decisions = [.make(kind: .action)]
        let clarifier = Clarifier(h.services())
        try await clarifier.processInbox()
        try await clarifier.processInbox()
        XCTAssertEqual(h.model.inputs.count, 1)
        var back = try await h.store.reminder(id: item.id)!
        back.list = "Reminders"
        back.title = "dentist, urgent"
        try await h.store.save(back)
        h.model.decisions = [.make(kind: .action, nextAction: "Call now")]
        try await clarifier.processInbox()
        XCTAssertEqual(h.model.inputs.count, 2)
    }

    func testNeedsPrepTriggersTheAgentLoopWhenAToolModelIsPresent() async throws {
        var h = Harness(); h.useToolModel = true
        h.contacts.people = [ContactMatch(name: "Alex", emails: ["alex@example.com"])]
        h.files.results = [URL(fileURLWithPath: "/tmp/deck.pdf")]
        try await h.inbox("email Alex the deck")
        h.model.decisions = [.make(kind: .action, nextAction: "Email Alex the deck", minutes: 30, needsPrep: true)]
        h.toolModel.turns = [
            AssistantTurn(text: "", toolCalls: [toolCall("lookup_contact", ["name": "Alex"])]),
            AssistantTurn(text: "", toolCalls: [toolCall("find_file", ["query": "deck"])]),
            AssistantTurn(text: "", toolCalls: [toolCall("draft_email", ["to": "alex@example.com", "subject": "Deck", "body": "Here.", "attachment_path": "/tmp/deck.pdf"])]),
            AssistantTurn(text: "Drafted.", toolCalls: []),
        ]
        try await Clarifier(h.services()).processInbox()
        XCTAssertEqual(h.mail.drafts.count, 1, "the agent ran even though minutes were over the two-minute cap")
        let approveN = try await h.store.reminders(in: "Approve", includeCompleted: false).count
        XCTAssertEqual(approveN, 1)
    }

    func testNeedsPrepFalseDoesNotRunTheAgent() async throws {
        var h = Harness(); h.useToolModel = true
        try await h.inbox("take out the recycling")
        h.model.decisions = [.make(kind: .action, nextAction: "Take out the recycling", needsPrep: false)]
        try await Clarifier(h.services()).processInbox()
        XCTAssertTrue(h.toolModel.conversations.isEmpty, "no agent run for a self-contained action")
    }

    func testMarkInboxSeenLeavesItemsAlone() async throws {
        let h = Harness()
        let item = try await h.inbox("old stuff")
        let n = try await Clarifier(h.services()).markInboxSeen()
        XCTAssertEqual(n, 1)
        try await Clarifier(h.services()).processInbox()
        let v111 = try await h.store.reminder(id: item.id)?.list
        XCTAssertEqual(v111, "Reminders")
        XCTAssertTrue(h.model.inputs.isEmpty)
    }

    func testInvalidDecisionIsSkippedAndLeavesItemInInbox() async throws {
        let h = Harness()
        let item = try await h.inbox("x")
        h.model.decisions = [.make(kind: .calendar, date: "next tuesday")]
        try await Clarifier(h.services()).processInbox()
        let v121 = try await h.store.reminder(id: item.id)?.list
        XCTAssertEqual(v121, "Reminders")
        let v123 = await h.ledger.isProcessed(item)
        XCTAssertFalse(v123)
    }

    func testAuthFailureStopsTheRun() async throws {
        struct Auth: LanguageModel {
            let name = "auth"
            func respond<T: ClarifyOutput>(instructions: String, input: String, as type: T.Type) async throws -> T { throw ModelError.authFailed("401") }
        }
        let h = Harness()
        try await h.inbox("a"); try await h.inbox("b")
        var s = h.services(); s.model = Auth()
        do { try await Clarifier(s).processInbox(); XCTFail("expected throw") } catch ModelError.authFailed { }
    }

    func testTwoMinuteRecipeRunsOnlyWhenEnabledAndShort() async throws {
        let h = Harness()
        h.contacts.people = [ContactMatch(name: "Alex", emails: ["alex@example.com"])]
        h.files.results = [URL(fileURLWithPath: "/tmp/deck.pdf")]
        try await h.inbox("email Alex the deck")
        h.model.decisions = [.make(kind: .action, minutes: 2, recipe: .emailWithAttachment)]
        h.model.slots = [.make(recipient: "Alex", subject: "Deck", body: "Here it is", attachment: "deck")]
        try await Clarifier(h.services()).processInbox()
        XCTAssertEqual(h.mail.drafts.count, 1)

        let h2 = Harness()
        try await h2.inbox("email Alex the deck")
        h2.model.decisions = [.make(kind: .action, minutes: 30, recipe: .emailWithAttachment)]
        try await Clarifier(h2.services()).processInbox()
        XCTAssertEqual(h2.mail.drafts.count, 0)

        var h3 = Harness()
        h3.settings.autoRunRecipes = false
        try await h3.inbox("email Alex the deck")
        h3.model.decisions = [.make(kind: .action, minutes: 1, recipe: .emailWithAttachment)]
        try await Clarifier(h3.services()).processInbox()
        XCTAssertEqual(h3.mail.drafts.count, 0)
    }
}
