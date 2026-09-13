import XCTest
@testable import ClarifyKit

final class RecipesTests: XCTestCase {
    func action(_ h: Harness, _ title: String) async throws -> ReminderItem {
        try await h.store.create(NewReminder(title: title, notes: Header(["kind": "action"]).render(body: ""), list: "Next Actions"))
    }

    func testEmailDraftsAndCreatesApproveThenApprovalSendsAndMovesToWaiting() async throws {
        let h = Harness()
        h.contacts.people = [ContactMatch(name: "Alex Moreno", emails: ["alex@example.com"])]
        h.files.results = [URL(fileURLWithPath: "/tmp/project-deck.pdf")]
        let item = try await action(h, "@computer Email Alex the project deck")
        h.model.slots = [.make(recipient: "Alex", subject: "Project deck", body: "Attached.", attachment: "project deck")]
        let recipes = Recipes(h.services())
        try await recipes.run(.emailWithAttachment, for: item, decision: .make(kind: .action, recipe: .emailWithAttachment))

        XCTAssertEqual(h.mail.drafts, [.init(to: "alex@example.com", subject: "Project deck", body: "Attached.", attachment: URL(fileURLWithPath: "/tmp/project-deck.pdf"))])
        XCTAssertTrue(h.mail.sent.isEmpty)
        let approvals = try await h.store.reminders(in: "Approve", includeCompleted: false)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals[0].header?["for"], item.id)

        var done = approvals[0]; done.isCompleted = true
        try await h.store.save(done)
        try await recipes.approve(done)
        XCTAssertEqual(h.mail.sent.count, 1)
        let source = try await h.store.reminder(id: item.id)!
        XCTAssertEqual(source.list, "Waiting For")
        XCTAssertEqual(source.header?["delegated_to"], "alex@example.com")
        let v30 = await h.ledger.entry(for: done.id)?.pending
        XCTAssertNil(v30)
    }

    func testEmailWithNoContactEmailWritesNoteAndNoDraft() async throws {
        let h = Harness()
        h.contacts.people = [ContactMatch(name: "Alex", phones: ["+1555"])]
        let item = try await action(h, "Email Alex the deck")
        h.model.slots = [.make(recipient: "Alex", subject: "Deck", attachment: "deck")]
        try await Recipes(h.services()).run(.emailWithAttachment, for: item, decision: .make(kind: .action))
        XCTAssertTrue(h.mail.drafts.isEmpty)
        let v41 = try await h.store.reminder(id: item.id)!.body.contains("no email")
        XCTAssertTrue(v41)
        let v43 = try await h.store.reminders(in: "Approve", includeCompleted: false).count
        XCTAssertEqual(v43, 0)
    }

    func testAmbiguousFilesBecomeChoicesAndChoosingOneDraftsAndRetiresOthers() async throws {
        let h = Harness()
        h.contacts.people = [ContactMatch(name: "Alex", emails: ["w@example.com"])]
        h.files.results = ["/a/deck-v1.pdf", "/a/deck-v2.pdf", "/a/deck-final.pdf"].map { URL(fileURLWithPath: $0) }
        let item = try await action(h, "Email Alex the deck")
        h.model.slots = [.make(recipient: "Alex", subject: "Deck", body: "b", attachment: "deck")]
        let recipes = Recipes(h.services())
        try await recipes.run(.emailWithAttachment, for: item, decision: .make(kind: .action))
        XCTAssertTrue(h.mail.drafts.isEmpty)
        let choices = try await h.store.reminders(in: "Approve", includeCompleted: false)
        XCTAssertEqual(choices.count, 3)

        var chosen = choices[1]; chosen.isCompleted = true
        try await h.store.save(chosen)
        try await recipes.approve(chosen)
        XCTAssertEqual(h.mail.drafts.first?.attachment?.lastPathComponent, "deck-v2.pdf")
        let remaining = try await h.store.reminders(in: "Approve", includeCompleted: false)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0].title.hasPrefix("Send 'Deck'"))
        let v66 = try await h.store.reminders(in: "Trash", includeCompleted: false).count
        XCTAssertEqual(v66, 2)
    }

    func testMessageWaitsForApprovalThenSends() async throws {
        let h = Harness()
        h.contacts.people = [ContactMatch(name: "Mom", phones: ["+16175550100"])]
        let item = try await action(h, "Text mom the address")
        h.model.slots = [.make(recipient: "Mom", body: "Rua da Prata 12, check-in 3pm")]
        let recipes = Recipes(h.services())
        try await recipes.run(.message, for: item, decision: .make(kind: .action))
        XCTAssertTrue(h.messages.sent.isEmpty)
        var approval = try await h.store.reminders(in: "Approve", includeCompleted: false)[0]
        approval.isCompleted = true
        try await recipes.approve(approval)
        XCTAssertEqual(h.messages.sent.count, 1)
        XCTAssertEqual(h.messages.sent[0].0, "+16175550100")
    }

    func testMessageBodyThatRestatesTheInstructionIsRefused() async throws {
        let h = Harness()
        h.contacts.people = [ContactMatch(name: "Alex", phones: ["+1555"])]
        let item = try await action(h, "@phone Text Alex the Airbnb address")
        h.model.slots = [.make(recipient: "Alex", body: "Text Alex the Airbnb address")]
        try await Recipes(h.services()).run(.message, for: item, decision: .make(kind: .action))
        let approvals = try await h.store.reminders(in: "Approve", includeCompleted: false)
        XCTAssertTrue(approvals.isEmpty)
        let saved = try await h.store.reminder(id: item.id)!
        XCTAssertTrue(saved.body.contains("Put the message in the notes"))
        XCTAssertTrue(Recipes.isRealBody("Rua da Prata 12, check-in 3pm", itemTitle: "@phone Text mom the address"))
        XCTAssertTrue(Recipes.isRealBody("hello from clarify", itemTitle: "@phone Text Clarify Tester hello from clarify"), "content that is part of the title is still content")
        XCTAssertFalse(Recipes.isRealBody("Send mom the address", itemTitle: "text mom the address"))
    }

    func testInvalidSlotsAnnotateInsteadOfActing() async throws {
        let h = Harness()
        let item = try await action(h, "Email someone")
        h.model.slots = [.make()]
        try await Recipes(h.services()).run(.emailWithAttachment, for: item, decision: .make(kind: .action))
        XCTAssertTrue(h.mail.drafts.isEmpty)
        let v91 = try await h.store.reminder(id: item.id)!.body.contains("skipped")
        XCTAssertTrue(v91)
    }

    func testContactLookupWritesDetailsIntoNotes() async throws {
        let h = Harness()
        h.contacts.people = [ContactMatch(name: "Dr. Patel", phones: ["617 555 0100"])]
        let item = try await action(h, "@phone Call Dr. Patel")
        h.model.slots = [.make(recipient: "Patel", field: "phone")]
        try await Recipes(h.services()).run(.contactLookup, for: item, decision: .make(kind: .action))
        let saved = try await h.store.reminder(id: item.id)!
        XCTAssertTrue(saved.body.contains("617 555 0100"))
        XCTAssertEqual(saved.header?["kind"], "action")
    }
}
