import SwiftUI
import ClarifyKit

/// Brings an accessory app's window to the front. A menu bar app does not
/// activate on its own, so a freshly opened Settings or Engage window can hide
/// behind whatever the user was looking at.
@MainActor
func bringWindowToFront(matching predicate: @escaping (NSWindow) -> Bool) {
    func raise(_ attempt: Int) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: predicate) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { raise(attempt + 1) }
        }
    }
    raise(0)
}

struct MenuBarView: View {
    @ObservedObject var daemon: Daemon
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Clarify").font(.headline)
                Spacer()
                Text(daemon.status).foregroundStyle(.secondary)
                Toggle("Pause", isOn: $daemon.paused).toggleStyle(.switch).labelsHidden().accessibilityLabel("Pause")
            }
            HStack(spacing: 16) {
                Label("\(daemon.inboxCount) in inbox", systemImage: "tray")
                Label("\(daemon.approvalsWaiting) to approve", systemImage: "checkmark.circle")
            }
            .font(.callout)
            Text(daemon.modelStatus)
                .font(.caption)
                .foregroundStyle(daemon.modelStatus.contains("ready") ? Color.secondary : Color.red)
                .accessibilityIdentifier("modelStatus")

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(daemon.log.suffix(5)) { line in
                    Text(line.text).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                }
                if daemon.log.isEmpty { Text("No activity yet").font(.caption).foregroundStyle(.tertiary) }
            }
            .accessibilityIdentifier("log")

            Divider()
            HStack {
                Button("Engage…") {
                    openWindow(id: "engage")
                    bringWindowToFront { $0.title.localizedCaseInsensitiveContains("engage") }
                }
                Button("Process existing") { Task { await daemon.processExisting() } }
                Menu("More") {
                    Button("Run weekly review now") { Task { await daemon.weeklyReview() } }
                    Button("Run daily sweep now") { Task { await daemon.dailySweep() } }
                    Button("Check Mail now") { Task { await daemon.checkMail() } }
                }
            }
            .disabled(!daemon.ready)
            if !daemon.ready {
                Button("Retry start") { Task { await daemon.ensureStarted() } }
            }
            HStack {
                Button("Settings…") {
                    openSettings()
                    bringWindowToFront { $0.title.localizedCaseInsensitiveContains("setting") }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
    }
}

struct EngageView: View {
    @ObservedObject var daemon: Daemon
    @State private var request = ""
    @State private var results: [ReminderItem] = []
    @State private var searching = false
    @State private var staged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What do you have right now?").font(.headline)
                Spacer()
                Text("\(daemon.status) · \(daemon.log.last?.text ?? "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier("daemonStatus")
            }
            HStack {
                TextField("twenty minutes, low energy, at the airport", text: $request)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("engageField")
                    .onSubmit { run() }
                Button("Find") { run() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("engageFind")
                    .disabled(request.isEmpty || searching || !daemon.ready)
            }
            List(results) { item in
                VStack(alignment: .leading) {
                    Text(item.title)
                    if let h = item.header {
                        Text([h["minutes"].map { "\($0) min" }, h["energy"], h["project"]].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("engageResult")
            }
            .accessibilityIdentifier("engageResults")
            HStack {
                if searching { ProgressView().controlSize(.small) }
                Text(searching ? "Thinking…" : results.isEmpty ? "" : "\(results.count) candidate\(results.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("engageStatus")
                Spacer()
                Button(staged ? "Staged" : "Stage to Today") { Task { await daemon.stage(results); staged = true } }
                    .disabled(results.isEmpty || staged)
                    .accessibilityIdentifier("engageStage")
            }
        }
        .padding(16)
        .onAppear { if !daemon.engageRequest.isEmpty { request = daemon.engageRequest; run() } }
        .onChange(of: daemon.engageRequest) { _, new in if !new.isEmpty { request = new; run() } }
    }

    private func run() {
        guard !request.isEmpty else { return }
        searching = true; staged = false
        Task {
            results = await daemon.engage(request)
            searching = false
        }
    }
}
