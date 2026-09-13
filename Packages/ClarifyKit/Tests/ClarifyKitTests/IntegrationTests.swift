import XCTest
@testable import ClarifyKit

/// Real-wiring tests. Each one skips with a reason when its environment is absent,
/// so the default `swift test` stays offline and prompt-free.
///   CLARIFY_EVENTKIT_TESTS=1   real Reminders and Calendar, using the "Clarify Test" list
///   CLARIFY_FM_TESTS=1         on-device Foundation Models
///   CLARIFY_ENDPOINT_URL=...   an OpenAI-compatible server, plus CLARIFY_ENDPOINT_MODEL
///   CLARIFY_MAIL_TESTS=1       creates and deletes a Mail draft to user@example.com
final class EventKitStoreTests: XCTestCase {
    static let list = "Clarify Test"

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLARIFY_EVENTKIT_TESTS"] == "1", "set CLARIFY_EVENTKIT_TESTS=1")
    }

    func testCreateMoveHeaderCompleteRoundTrip() async throws {
        let store = EventKitStore()
        try await store.requestAccess()
        try await store.ensureLists([Self.list])
        let lists = try await store.listNames()
        XCTAssertTrue(lists.contains(Self.list))
        let inbox = try await store.inboxListName()
        XCTAssertFalse(inbox.isEmpty)

        let header = Header(["kind": "action", "context": "@phone"])
        let created = try await store.create(NewReminder(title: "integration test item", notes: header.render(body: "user text"), list: Self.list,
                                                         startDate: DateComponents(year: 2026, month: 9, day: 12)))
        XCTAssertFalse(created.id.isEmpty)
        var fetched = try await store.reminder(id: created.id)
        XCTAssertEqual(fetched?.header?["context"], "@phone")
        XCTAssertEqual(fetched?.body, "user text")
        XCTAssertEqual(fetched?.startDate?.day, 12)

        fetched!.title = "integration test item moved"
        fetched!.notes = Header(["kind": "waiting"]).apply(to: fetched!.notes)
        try await store.save(fetched!)
        let inList = try await store.reminders(in: Self.list, includeCompleted: false)
        XCTAssertTrue(inList.contains { $0.id == created.id && $0.title.hasSuffix("moved") && $0.header?["kind"] == "waiting" && $0.body == "user text" })

        fetched!.isCompleted = true
        try await store.save(fetched!)
        let open = try await store.reminders(in: Self.list, includeCompleted: false)
        XCTAssertFalse(open.contains { $0.id == created.id })
        let all = try await store.reminders(in: Self.list, includeCompleted: true)
        XCTAssertTrue(all.contains { $0.id == created.id && $0.isCompleted })
    }
}

final class FoundationModelTests: XCTestCase {
    func testClarifyDecisionShapeOnDevice() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLARIFY_FM_TESTS"] == "1", "set CLARIFY_FM_TESTS=1")
        if case .failure(let e) = FoundationLanguageModel.availability() { throw XCTSkip(e.localizedDescription) }
        let model = FoundationLanguageModel()
        let d = try await model.respond(instructions: Prompts.text("clarify"), input: "Inbox item: email Alex the project deck\nToday: 2026-09-12\nContexts: @computer @phone\nAreas: (none listed)", as: ClarifyDecision.self)
        XCTAssertNoThrow(try d.validate())
        XCTAssertTrue(Kind.allValues.contains(d.kind))
    }
}

final class EndpointModelTests: XCTestCase {
    func testStrictSchemaRoundTripAgainstLocalServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["CLARIFY_ENDPOINT_URL"], let modelName = env["CLARIFY_ENDPOINT_MODEL"] else { throw XCTSkip("set CLARIFY_ENDPOINT_URL and CLARIFY_ENDPOINT_MODEL") }
        let model = EndpointLanguageModel(baseURL: URL(string: url)!, apiKey: env["CLARIFY_ENDPOINT_KEY"], model: modelName, timeout: 180)
        let d = try await model.respond(instructions: Prompts.text("clarify"), input: "Inbox item: renew passport\nToday: 2026-09-12\nContexts: @computer @phone @home\nAreas: Admin", as: ClarifyDecision.self)
        XCTAssertNoThrow(try d.validate())
        XCTAssertEqual(d.kind, "project", "renew passport is the canonical multi-step example")
    }

    func testAuthFailureIsSurfacedNotSwallowed() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["CLARIFY_ENDPOINT_URL"] else { throw XCTSkip("set CLARIFY_ENDPOINT_URL") }
        let server = FakeStatusServer(status: 401, body: #"{"error":"bad key"}"#)
        let port = try server.start()
        defer { server.stop() }
        _ = url
        let model = EndpointLanguageModel(baseURL: URL(string: "http://127.0.0.1:\(port)")!, apiKey: "x", model: "m", timeout: 10)
        do {
            _ = try await model.respond(instructions: "i", input: "x", as: EngageQuery.self)
            XCTFail("expected authFailed")
        } catch ModelError.authFailed { }
    }

    func testExtractJSONHandlesFencesAndProse() {
        XCTAssertEqual(EndpointLanguageModel.extractJSON("```json\n{\"a\":1}\n```"), "{\"a\":1}")
        XCTAssertEqual(EndpointLanguageModel.extractJSON("Sure: {\"a\":{\"b\":\"}\"}} trailing"), "{\"a\":{\"b\":\"}\"}}")
    }
}

final class MailBridgeTests: XCTestCase {
    func testDraftWithAttachmentThenDelete() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLARIFY_MAIL_TESTS"] == "1", "set CLARIFY_MAIL_TESTS=1")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clarify-attach-\(UUID()).txt")
        try "attachment".write(to: file, atomically: true, encoding: .utf8)
        let subject = "Clarify integration draft \(UUID())"
        try await MailApp().draft(to: "user@example.com", subject: subject, body: "Do not send.", attachment: file)
        let count = try await AppleScript.run("""
        tell application "Mail"
            set found to (every outgoing message whose subject is \(AppleScript.quoted(subject)))
            set n to count of attachments of content of item 1 of found
            delete item 1 of found
            return n
        end tell
        """)
        XCTAssertEqual(count, "1")
    }
}

/// Minimal HTTP server that answers every request with one status and body.
final class FakeStatusServer: @unchecked Sendable {
    let status: Int, body: String
    private var socket: Int32 = -1
    private var thread: Thread?
    init(status: Int, body: String) { self.status = status; self.body = body }

    func start() throws -> UInt16 {
        socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        let bindResult = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bindResult == 0, listen(socket, 4) == 0 else { throw BridgeError.scriptFailed("bind failed") }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(socket, $0, &len) } }
        let port = UInt16(bigEndian: bound.sin_port)
        let sock = socket, status = status, body = body
        thread = Thread {
            while true {
                let client = accept(sock, nil, nil)
                guard client >= 0 else { return }
                var buf = [UInt8](repeating: 0, count: 65536)
                _ = read(client, &buf, buf.count)
                let response = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = response.withCString { write(client, $0, strlen($0)) }
                close(client)
            }
        }
        thread?.start()
        return port
    }

    func stop() { close(socket) }
}

final class OpenRouterToolLoopTests: XCTestCase {
    func testRealChainLooksUpContactThenDraftsText() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["CLARIFY_OPENROUTER_KEY"] else { throw XCTSkip("set CLARIFY_OPENROUTER_KEY") }
        let model = env["CLARIFY_OPENROUTER_MODEL"] ?? "anthropic/claude-sonnet-5"
        let endpoint = EndpointLanguageModel(baseURL: URL(string: "https://openrouter.ai/api")!, apiKey: key, model: model,
            timeout: 120, extraHeaders: ["HTTP-Referer": "https://github.com/bradegan/clarify", "X-Title": "Clarify"])

        let store = MemoryStore()
        let contacts = FakeContacts(); contacts.people = [ContactMatch(name: "Sam Rivera", phones: ["+16105551212"], emails: ["sam@example.com"])]
        let services = Services(store: store, model: endpoint, ledger: Ledger(url: nil), contacts: contacts,
            files: FakeFiles(), mail: FakeMail(), messages: FakeMessages(), settings: Settings(), toolModel: endpoint,
            now: { Date(timeIntervalSince1970: 1_789_200_000) })
        let item = ReminderItem(id: "src", title: "@phone Text Sam I'm running ten minutes late", list: "Next Actions")
        let outcome = try await ToolLoop(services).run(item: item, goal: "Text Sam that I'm running ten minutes late")

        XCTAssertTrue(outcome.steps.contains { $0.contains("looked up") }, "must resolve the contact: \(outcome.steps)")
        XCTAssertTrue(outcome.steps.contains { $0.contains("drafted a text") }, "must draft the text: \(outcome.steps)")
        let approvals = try await store.reminders(in: "Approve", includeCompleted: false)
        XCTAssertEqual(approvals.count, 1, "the text waits in Approve, unsent")
        XCTAssertTrue(approvals[0].title.contains("+16105551212"), "used the looked-up number: \(approvals[0].title)")
    }
}

final class ExaTests: XCTestCase {
    func testAnswerReturnsGroundedTextWithSources() async throws {
        guard let key = ProcessInfo.processInfo.environment["CLARIFY_EXA_KEY"] else { throw XCTSkip("set CLARIFY_EXA_KEY") }
        let result = try await ExaClient(apiKey: key).answer("What is the phone number to schedule a US passport appointment?")
        XCTAssertFalse(result.answer.isEmpty)
        XCTAssertFalse(result.sources.isEmpty, "an answer should carry citations")
        XCTAssertTrue(result.sources.allSatisfy { $0.url.hasPrefix("http") })
    }
}
