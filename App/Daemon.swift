import Foundation
import Combine
import EventKit
import UserNotifications
import ServiceManagement
import ClarifyKit

/// The resident process: owns the store, reacts to Reminders changes, runs the
/// scheduled sweeps, and exposes actions to the menu bar.
@MainActor
final class Daemon: ObservableObject {
    let configuration: Configuration
    @Published var settings: Settings { didSet { settingsChanged() } }
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var status = "Starting"
    @Published private(set) var inboxCount = 0
    @Published private(set) var approvalsWaiting = 0
    @Published var paused = false { didSet { status = paused ? "Paused" : "Watching" } }
    @Published private(set) var ready = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var modelStatus = ""
    @Published var engageRequest = ""

    private var store: Store
    private var ledger: Ledger
    private var services: Services?
    private var started = false
    private var changeObserver: NSObjectProtocol?
    private var debounce: Task<Void, Never>?
    private var dailyTask: Task<Void, Never>?
    private var weeklyTask: Task<Void, Never>?
    private var mailTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var lastMailScan: Date

    init(configuration: Configuration) {
        self.configuration = configuration
        self.settings = SettingsStore.load(from: configuration.settingsURL)
        self.ledger = Ledger(url: configuration.ledgerURL)
        self.lastMailScan = Date().addingTimeInterval(-3600)
        if configuration.uiTest {
            let memory = MemoryStore()
            UITestSeed.populate(memory)
            self.store = memory
        } else {
            self.store = EventKitStore()
        }
    }

    // MARK: lifecycle

    func start() async {
        guard !started else { return }
        started = true
        do {
            if let ek = store as? EventKitStore {
                try await ek.requestAccess()
                if await !ek.calendarGranted { append("Calendar access not granted: dated items will wait in the inbox until it is allowed in System Settings > Privacy & Security > Calendars.") }
                changeObserver = NotificationCenter.default.addObserver(forName: EventKitStore.changeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.storeChanged() }
                }
            }
            try await store.ensureBuckets()
            rebuildServices()
            if await ledger.count == 0, let s = services {
                let n = try await Clarifier(s).markInboxSeen()
                if n > 0 { append("First run: left \(n) existing item(s) alone. Use Process existing to clarify them.") }
            }
            ready = true
            status = "Watching"
            if !configuration.uiTest {
                Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
            }
            append("Watching '\(try await store.inboxListName())' with \(services?.model.name ?? "no model")")
            scheduleSweeps()
            await refreshCounts()
            await processInbox()
        } catch {
            started = false
            status = "Not running"
            append("Start failed: \(error.localizedDescription). Retrying on the next action.")
        }
    }

    /// Start again after a failed start, for the popover and URL commands.
    func ensureStarted() async {
        if !ready { await start() }
    }

    private func rebuildServices() {
        var model: LanguageModel = FoundationLanguageModel()
        var toolModel: ToolChatModel?
        switch settings.provider {
        case .onDevice:
            model = FoundationLanguageModel()
        case .endpoint:
            let url = URL(string: settings.endpointURL) ?? URL(string: "http://127.0.0.1:1234")!
            let endpoint = EndpointLanguageModel(baseURL: url, apiKey: Keychain.read(), model: settings.endpointModel, timeout: settings.endpointTimeout)
            model = endpoint; toolModel = endpoint
        case .openrouter:
            let endpoint = EndpointLanguageModel(baseURL: URL(string: "https://openrouter.ai/api")!, apiKey: Keychain.read(),
                model: settings.openrouterModel, timeout: settings.endpointTimeout,
                extraHeaders: ["HTTP-Referer": "https://github.com/bradegan/clarify", "X-Title": "Clarify"])
            model = endpoint; toolModel = endpoint
        }
        let chosen: LanguageModel = configuration.uiTest ? UITestModel() : model
        let webKey = Keychain.read(account: "exa-key")
        let web: WebSearchBridge? = (settings.webSearch && !configuration.uiTest && (webKey?.isEmpty == false)) ? ExaClient(apiKey: webKey!) : nil
        services = Services(store: store, model: chosen, ledger: ledger,
                            contacts: ContactsStore(), files: SpotlightFiles(), mail: MailApp(), messages: MessagesApp(),
                            settings: settings, toolModel: settings.useAgentLoop ? toolModel : nil, web: web,
                            log: { [weak self] line in Task { @MainActor in self?.append(line) } })
        Task { await probeModel() }
    }

    /// One cheap check so the popover can say whether the chosen model will answer.
    func probeModel() async {
        guard !configuration.uiTest else { modelStatus = "ui-test model"; return }
        switch settings.provider {
        case .onDevice:
            switch FoundationLanguageModel.availability() {
            case .success: modelStatus = "On-device model ready"
            case .failure(let e): modelStatus = "On-device unavailable: \(e.localizedDescription)"
            }
        case .endpoint:
            guard let url = URL(string: settings.endpointURL)?.appendingPathComponent("v1/models") else { modelStatus = "Endpoint URL is not valid"; return }
            var request = URLRequest(url: url); request.timeoutInterval = 5
            if let key = Keychain.read(), !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ids = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
                if code == 200, ids.contains(settings.endpointModel) { modelStatus = "Endpoint ready: \(settings.endpointModel)" }
                else if code == 200 { modelStatus = "Endpoint reachable but '\(settings.endpointModel)' is not loaded" }
                else { modelStatus = "Endpoint returned HTTP \(code)" }
            } catch {
                modelStatus = "Endpoint unreachable at \(settings.endpointURL). On-device fallback is off; fix Settings."
            }
        case .openrouter:
            guard let key = Keychain.read(), !key.isEmpty else { modelStatus = "OpenRouter key missing. Add it in Settings."; return }
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!); request.timeoutInterval = 5
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                modelStatus = code == 200 ? "OpenRouter ready: \(settings.openrouterModel)" : "OpenRouter rejected the key (HTTP \(code))"
            } catch { modelStatus = "OpenRouter unreachable. Check the network." }
        }
        append(modelStatus)
    }

    func handle(_ command: RemoteCommand) async {
        append("Command: \(command)")
        await ensureStarted()
        switch command {
        case .process: await processInbox()
        case .processExisting: await processExisting()
        case .weeklyReview: await weeklyReview()
        case .dailySweep: await dailySweep()
        case .checkMail: await checkMail()
        case .engage(let q):
            engageRequest = q
            NotificationCenter.default.post(name: .clarifyOpenEngage, object: nil)
        }
    }

    private func settingsChanged() {
        try? SettingsStore.save(settings, to: configuration.settingsURL)
        guard started else { return }
        rebuildServices()
        scheduleSweeps()
        append("Settings saved. Model: \(services?.model.name ?? "none")")
    }

    func setEndpointKey(_ key: String) {
        do { try Keychain.write(key); rebuildServices() } catch { append("Keychain write failed: \(error.localizedDescription)") }
    }

    func setExaKey(_ key: String) {
        do { try Keychain.write(key, account: "exa-key"); rebuildServices(); append("Web search \(key.isEmpty ? "off" : "on")") }
        catch { append("Keychain write failed: \(error.localizedDescription)") }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { append("Launch at login failed: \(error.localizedDescription)") }
    }

    // MARK: reacting to Reminders

    /// Change notifications arrive in bursts, including for Clarify's own saves.
    /// The debounce only delays the start; processing runs in its own task so a
    /// later burst can never cancel a model call in flight. A burst that lands
    /// mid-run schedules one more pass.
    private func storeChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            Task { await self.processInbox() }
        }
    }

    private var processing = false
    private var rerunRequested = false

    func processInbox() async {
        guard ready, !paused, let s = services else { return }
        if processing { rerunRequested = true; return }
        processing = true
        defer { processing = false }
        repeat {
            rerunRequested = false
            do {
                let touched = try await Clarifier(s).processInbox()
                try await runApprovals(s)
                await refreshCounts()
                if !touched.isEmpty { notify("Clarified \(touched.count) item\(touched.count == 1 ? "" : "s")", body: touched.map(\.title).joined(separator: ", ")) }
            } catch {
                append("Processing stopped: \(error.localizedDescription)")
                status = "Error"
            }
        } while rerunRequested
    }

    private func runApprovals(_ s: Services) async throws {
        let approvals = try await store.reminders(in: Bucket.approve.rawValue, includeCompleted: true)
        for a in approvals where a.isCompleted {
            guard await ledger.entry(for: a.id)?.pending != nil else { continue }
            do { try await Recipes(s).approve(a) } catch { append("Approval '\(a.title)' failed: \(error.localizedDescription)") }
        }
    }

    func processExisting() async {
        guard let s = services else { return }
        do {
            let inbox = try await store.inboxListName()
            let items = try await store.reminders(in: inbox, includeCompleted: false)
            for item in items { try await ledger.record(item.id, hash: "force-\(UUID())") }
            append("Re-queued \(items.count) inbox item(s)")
            _ = s
            await processInbox()
        } catch { append("Could not re-queue: \(error.localizedDescription)") }
    }

    private func refreshCounts() async {
        guard let inbox = try? await store.inboxListName() else { return }
        inboxCount = (try? await store.reminders(in: inbox, includeCompleted: false).count) ?? 0
        approvalsWaiting = (try? await store.reminders(in: Bucket.approve.rawValue, includeCompleted: false).count) ?? 0
    }

    // MARK: schedules

    private func scheduleSweeps() {
        dailyTask?.cancel(); weeklyTask?.cancel(); mailTask?.cancel(); fallbackTask?.cancel()
        guard ready, !configuration.uiTest else { return }
        let daily = settings.dailySweepHour, weekday = settings.weeklyReviewWeekday, weeklyHour = settings.weeklyReviewHour
        dailyTask = Task { [weak self] in
            while !Task.isCancelled {
                let next = Schedule.next(hour: daily, weekday: nil, after: Date())
                try? await Task.sleep(until: .now + .seconds(next.timeIntervalSinceNow), clock: .continuous)
                guard !Task.isCancelled else { return }
                await self?.dailySweep()
            }
        }
        weeklyTask = Task { [weak self] in
            while !Task.isCancelled {
                let next = Schedule.next(hour: weeklyHour, weekday: weekday, after: Date())
                try? await Task.sleep(until: .now + .seconds(next.timeIntervalSinceNow), clock: .continuous)
                guard !Task.isCancelled else { return }
                await self?.weeklyReview()
            }
        }
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.fallbackPass()
            }
        }
        let interval = max(1, settings.mailWatchIntervalMinutes)
        mailTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval * 60))
                guard !Task.isCancelled else { return }
                await self?.checkMail()
            }
        }
    }

    /// Safety net for a missed change notification: once a minute, if the inbox
    /// holds anything the ledger has not seen, run a pass and say so in the log.
    private func fallbackPass() async {
        guard ready, !paused, !processing, let s = services else { return }
        guard let inbox = try? await store.inboxListName(),
              let items = try? await store.reminders(in: inbox, includeCompleted: false) else { return }
        var pending = 0
        for item in items where await !ledger.isProcessed(item) { pending += 1 }
        let approvals = (try? await store.reminders(in: Bucket.approve.rawValue, includeCompleted: true)) ?? []
        var approvalsPending = 0
        for a in approvals where a.isCompleted { if await ledger.entry(for: a.id)?.pending != nil { approvalsPending += 1 } }
        guard pending > 0 || approvalsPending > 0 else { return }
        append("Fallback pass: \(pending) inbox item(s) and \(approvalsPending) approval(s) were waiting without a change notification")
        _ = s
        await processInbox()
    }

    func dailySweep() async {
        guard let s = services, !paused else { return }
        do {
            _ = try await Review(s).dailySweep()
            await processInbox()
            notify("Good morning", body: try await Review(s).morningBriefing())
        } catch { append("Daily sweep failed: \(error.localizedDescription)") }
    }

    func weeklyReview() async {
        guard let s = services else { return }
        do {
            let created = try await Review(s).weekly()
            notify("Weekly review ready", body: "\(created.count) item\(created.count == 1 ? "" : "s") in Weekly Review")
        } catch { append("Weekly review failed: \(error.localizedDescription)") }
    }

    func checkMail() async {
        guard let s = services, !paused else { return }
        let since = lastMailScan
        lastMailScan = Date()
        do {
            let hits = try await Watcher(s).scan(since: since)
            if !hits.isEmpty { append("Mail: \(hits.count) Waiting For item(s) answered"); await refreshCounts() }
        } catch { append("Mail check failed: \(error.localizedDescription)") }
    }

    // MARK: engage

    func engage(_ request: String) async -> [ReminderItem] {
        guard let s = services else { return [] }
        do {
            let engage = Engage(s)
            let criteria = try await engage.parse(request)
            return try await engage.candidates(criteria)
        } catch { append("Engage failed: \(error.localizedDescription)"); return [] }
    }

    func stage(_ items: [ReminderItem]) async {
        guard let s = services else { return }
        do { try await Engage(s).stage(items); append("Staged \(items.count) item(s) to Today") } catch { append("Stage failed: \(error.localizedDescription)") }
    }

    // MARK: output

    private func append(_ text: String) {
        let stamp = Daemon.stamp.string(from: Date())
        FileHandle.standardError.write(Data("[clarify] \(stamp) \(text)\n".utf8))
        FileLog.write("\(stamp) \(text)", to: configuration.supportDirectory.appendingPathComponent("clarify.log"))
        log.append(LogLine(text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func notify(_ title: String, body: String) {
        append("\(title): \(body)")
        guard !configuration.uiTest else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension Daemon {
    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
}

/// Append-only log in Application Support, rotated at one megabyte, so a
/// stuck instance can be diagnosed after the fact.
enum FileLog {
    static func write(_ line: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
            try? fm.moveItem(at: url, to: url.deletingPathExtension().appendingPathExtension("previous.log").withReplacement())
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? Data((line + "\n").utf8).write(to: url)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

extension URL {
    func withReplacement() -> URL { try? FileManager.default.removeItem(at: self); return self }
}

enum Schedule {
    /// Next occurrence of `hour` (and `weekday` when given, 1 = Sunday) strictly after `after`.
    static func next(hour: Int, weekday: Int?, after: Date, calendar: Calendar = .current) -> Date {
        var comps = DateComponents(hour: hour, minute: 0, second: 0)
        comps.weekday = weekday
        return calendar.nextDate(after: after, matching: comps, matchingPolicy: .nextTime) ?? after.addingTimeInterval(3600)
    }
}
