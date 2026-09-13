import XCTest
@testable import ClarifyKit

final class EngageTests: XCTestCase {
    func action(_ h: Harness, _ title: String, context: String, minutes: Int, energy: String, since: String = "2026-09-01", due: DateComponents? = nil) async throws -> ReminderItem {
        try await h.store.create(NewReminder(title: title, notes: Header(["kind": "action", "context": context, "minutes": String(minutes), "energy": energy, "since": since]).render(body: ""), list: "Next Actions", dueDate: due))
    }

    func testFourCriteriaFilter() async throws {
        let h = Harness()
        let a = try await action(h, "call", context: "@phone", minutes: 5, energy: "low")
        _ = try await action(h, "deep work", context: "@computer", minutes: 90, energy: "high")
        let c = try await action(h, "anywhere", context: "@anywhere", minutes: 10, energy: "medium")
        _ = try await action(h, "long call", context: "@phone", minutes: 45, energy: "low")
        let all = try await h.store.reminders(in: "Next Actions", includeCompleted: false)

        let byContext = Engage.filter(all, .init(context: "@phone"), now: h.now)
        XCTAssertEqual(Set(byContext.map(\.id)), Set([a.id, c.id, "mem-4"]), "@anywhere items match every context")
        let tight = Engage.filter(all, .init(context: "@phone", minutes: 20, energy: .medium), now: h.now)
        XCTAssertEqual(tight.map(\.id), [a.id, c.id])
        let anywhere = Engage.filter(all, .init(context: "@errands", minutes: 20), now: h.now)
        XCTAssertEqual(anywhere.map(\.id), [c.id])
        XCTAssertEqual(Engage.filter(all, .init(energy: .low), now: h.now).count, 2)
    }

    func testOrderingPutsDueFirstThenOldest() async throws {
        let h = Harness()
        let old = try await action(h, "old", context: "@computer", minutes: 5, energy: "low", since: "2026-08-01")
        let new = try await action(h, "new", context: "@computer", minutes: 5, energy: "low", since: "2026-09-10")
        let due = try await action(h, "due", context: "@computer", minutes: 5, energy: "low", since: "2026-09-10", due: DateComponents(year: 2026, month: 9, day: 12))
        let all = try await h.store.reminders(in: "Next Actions", includeCompleted: false)
        XCTAssertEqual(Engage.filter(all, .init(), now: h.now).map(\.id), [due.id, old.id, new.id])
    }

    func testParseUsesModelAndStagesToToday() async throws {
        let h = Harness()
        let a = try await action(h, "call", context: "@phone", minutes: 5, energy: "low")
        h.model.queries = [EngageQuery(context: "@phone", minutes: 20, energy: "low")]
        let engage = Engage(h.services())
        let criteria = try await engage.parse("twenty minutes, low energy, phone")
        XCTAssertEqual(criteria, .init(context: "@phone", minutes: 20, energy: .low))
        let picks = try await engage.candidates(criteria)
        XCTAssertEqual(picks.map(\.id), [a.id])
        try await engage.stage(picks)
        let v44 = try await h.store.reminders(in: "Today", includeCompleted: false).map(\.title)
        XCTAssertEqual(v44, ["call"])
    }
}

final class ReviewTests: XCTestCase {
    func testFindingsAtBoundaries() async throws {
        var h = Harness()
        h.now = DateOnly.parse("2026-09-12")!
        func add(_ list: String, _ title: String, since: String, project: String? = nil, due: DateComponents? = nil) async throws {
            var header = Header(["kind": "x", "since": since])
            if let project { header["project"] = project }
            try await h.store.create(NewReminder(title: title, notes: header.render(body: ""), list: list, dueDate: due))
        }
        try await add("Next Actions", "stale", since: "2026-09-05")
        try await add("Next Actions", "fresh", since: "2026-09-06")
        try await add("Next Actions", "stale but due", since: "2026-09-01", due: DateComponents(year: 2026, month: 9, day: 20))
        try await add("Next Actions", "for proj", since: "2026-09-12", project: "Passport")
        try await add("Projects", "Passport", since: "2026-09-01")
        try await add("Projects", "Orphan", since: "2026-09-01")
        try await add("Waiting For", "overdue wait", since: "2026-09-07")
        try await add("Waiting For", "recent wait", since: "2026-09-08")
        try await add("Someday/Maybe", "old wish", since: "2026-08-13")
        try await add("Someday/Maybe", "new wish", since: "2026-08-14")
        try await h.store.create(NewReminder(title: "Areas and Goals", notes: "Area: Health\nGoal: Run a marathon\nGoal: Passport sorted", list: "Reference"))

        let found = try await Review(h.services()).findings()
        XCTAssertEqual(found.map { "\($0.rule.rawValue):\($0.title)" }, [
            "staleAction:stale", "projectWithoutAction:Orphan", "waitingOverdue:overdue wait", "somedayOld:old wish", "goalWithoutProject:Run a marathon",
        ])
    }

    func testWeeklyWritesOneDeterministicLinePerFindingWithoutAModelCall() async throws {
        var h = Harness()
        h.now = DateOnly.parse("2026-09-12")!
        try await h.store.create(NewReminder(title: "Orphan", notes: Header(["since": "2026-09-01"]).render(body: ""), list: "Projects"))
        try await h.store.create(NewReminder(title: "stale", notes: Header(["since": "2026-09-01"]).render(body: ""), list: "Next Actions"))
        let created = try await Review(h.services()).weekly()
        XCTAssertEqual(created.map(\.title), ["Still doing 'stale'? Do it, defer it, or drop it.", "Project 'Orphan' has no next action. Add one."])
        XCTAssertEqual(created[1].header?["rule"], "projectWithoutAction")
        XCTAssertTrue(h.model.inputs.isEmpty, "the weekly review makes no model call")
    }

    func testDailySweepSurfacesTickler() async throws {
        var h = Harness()
        h.now = DateOnly.parse("2026-09-12")!
        let due = try await h.store.create(NewReminder(title: "tickle", list: "Someday/Maybe", startDate: DateComponents(year: 2026, month: 9, day: 12)))
        let future = try await h.store.create(NewReminder(title: "later", list: "Someday/Maybe", startDate: DateComponents(year: 2026, month: 9, day: 13)))
        let moved = try await Review(h.services()).dailySweep()
        XCTAssertEqual(moved.map(\.id), [due.id])
        let v96 = try await h.store.reminder(id: due.id)?.list
        XCTAssertEqual(v96, "Reminders")
        let v98 = try await h.store.reminder(id: due.id)?.startDate
        XCTAssertNil(v98)
        let v100 = try await h.store.reminder(id: future.id)?.list
        XCTAssertEqual(v100, "Someday/Maybe")
    }
}

final class WatcherTests: XCTestCase {
    func testMatchingSenderCreatesApprovalByDefaultAndClosesWhenEnabled() async throws {
        var h = Harness()
        let waiting = try await h.store.create(NewReminder(title: "deck feedback", notes: Header(["kind": "waiting", "delegated_to": "Alex Moreno"]).render(body: ""), list: "Waiting For"))
        h.mail.messages = [
            MailMessage(sender: "Alex Moreno <alex@example.com>", subject: "Re: deck", received: h.now, excerpt: "Looks great, approved."),
            MailMessage(sender: "Someone Else <x@example.com>", subject: "hi", received: h.now, excerpt: "unrelated"),
        ]
        h.model.verdicts = [WatcherVerdict(closes: true, quote: "Looks great, approved.", reason: "explicit approval")]
        let hits = try await Watcher(h.services()).scan(since: h.now.addingTimeInterval(-60))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(h.model.inputs.count, 1, "unrelated sender must not cost a model call")
        let v117 = try await h.store.reminder(id: waiting.id)!.isCompleted
        XCTAssertFalse(v117)
        let approvals = try await h.store.reminders(in: "Approve", includeCompleted: false)
        XCTAssertEqual(approvals.count, 1)
        try await Recipes(h.services()).approve(approvals[0])
        let v122 = try await h.store.reminder(id: waiting.id)!.isCompleted
        XCTAssertTrue(v122)

        h.settings.autoCloseWaiting = true
        let w2 = try await h.store.create(NewReminder(title: "invoice", notes: Header(["kind": "waiting", "delegated_to": "x@example.com"]).render(body: ""), list: "Waiting For"))
        h.mail.messages = [MailMessage(sender: "x@example.com", subject: "paid", received: h.now, excerpt: "Paid today.")]
        h.model.verdicts = [WatcherVerdict(closes: true, quote: "Paid today.", reason: "paid")]
        try await Watcher(h.services()).scan(since: h.now.addingTimeInterval(-60))
        let v130 = try await h.store.reminder(id: w2.id)!.isCompleted
        XCTAssertTrue(v130)
    }

    func testNonClosingVerdictDoesNothing() async throws {
        let h = Harness()
        try await h.store.create(NewReminder(title: "x", notes: Header(["delegated_to": "Ann"]).render(body: ""), list: "Waiting For"))
        h.mail.messages = [MailMessage(sender: "Ann <a@example.com>", subject: "ack", received: h.now, excerpt: "Got it, will look.")]
        h.model.verdicts = [WatcherVerdict(closes: false, quote: "", reason: "only an acknowledgment")]
        let hits = try await Watcher(h.services()).scan(since: .distantPast)
        XCTAssertTrue(hits.isEmpty)
        let v141 = try await h.store.reminders(in: "Approve", includeCompleted: false).count
        XCTAssertEqual(v141, 0)
    }
}

final class LedgerTests: XCTestCase {
    func testPersistsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID()).json")
        let a = Ledger(url: url)
        try await a.record("r1", hash: "h1", pending: .sendMessage(handle: "+1", text: "hi"))
        let b = Ledger(url: url)
        let v152 = await b.entry(for: "r1")?.pending
        XCTAssertEqual(v152, .sendMessage(handle: "+1", text: "hi"))
        let v154 = await b.isProcessed(ReminderItem(id: "r1", title: "", list: "")) == false
        XCTAssertTrue(v154)
    }
}

final class SchemaValidationTests: XCTestCase {
    func testDecisionRejectsBadEnumRangeAndMissingDate() {
        XCTAssertThrowsError(try ClarifyDecision.make(kind: .action, minutes: 0).validate())
        XCTAssertThrowsError(try ClarifyDecision.make(kind: .calendar, date: "").validate())
        XCTAssertNoThrow(try ClarifyDecision.make(kind: .calendar, date: "2026-10-03").validate())
        var bad = ClarifyDecision.make(kind: .action); bad.energy = "extreme"
        XCTAssertThrowsError(try bad.validate())
        var badRecipe = ClarifyDecision.make(kind: .action); badRecipe.recipe = "fax"
        XCTAssertThrowsError(try badRecipe.validate())
    }

    func testEveryOutputDecodesFromItsOwnSchemaShape() throws {
        let decoder = JSONDecoder()
        let d = try decoder.decode(ClarifyDecision.self, from: Data(#"{"actionable":true,"kind":"action","outcome":"o","nextAction":"Call","context":"@phone","minutes":5,"energy":"low","area":"Unsorted","date":"","delegatedTo":"","recipe":"none","reason":"r","needsPrep":false}"#.utf8))
        XCTAssertNoThrow(try d.validate())
        let p = try decoder.decode(ProjectPlan.self, from: Data(#"{"purpose":"p","principles":["a"],"outcomeVision":"v","brainstorm":["b"],"nextActions":["Do","Do","Do"],"contexts":["@home","@home","@home"],"minutes":[1,2,3]}"#.utf8))
        XCTAssertNoThrow(try p.validate())
        for schema in [ClarifyDecision.jsonSchema, RecipeSlots.jsonSchema, ProjectPlan.jsonSchema, WatcherVerdict.jsonSchema, EngageQuery.jsonSchema] {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(schema.utf8)), "schema must be valid JSON")
        }
    }

    func testISO8601Parsing() {
        XCTAssertEqual(ISO8601.parse("2026-10-03")?.hasTime, false)
        XCTAssertEqual(ISO8601.parse("2026-10-03T14:00")?.hasTime, true)
        XCTAssertEqual(ISO8601.parse("2026-10-03T14:00:00Z")?.hasTime, true)
        XCTAssertNil(ISO8601.parse("next tuesday"))
    }
}
