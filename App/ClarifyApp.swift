import SwiftUI
import ClarifyKit

/// Starts the daemon at launch. A menu bar app has no window to hang a task on
/// until the user opens the popover, so the app delegate is the launch hook.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let daemon = Daemon(configuration: .fromProcess())
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await AppDelegate.daemon.start() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = RemoteCommand.parse(url) else { continue }
            Task { await AppDelegate.daemon.handle(command) }
        }
    }
}

@main
struct ClarifyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var daemon = AppDelegate.daemon

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(daemon: daemon)
                .frame(width: 360)
        } label: {
            MenuBarLabel(daemon: daemon)
        }
        .menuBarExtraStyle(.window)

        Window("Clarify Engage", id: "engage") {
            EngageView(daemon: daemon)
                .frame(minWidth: 420, minHeight: 320)
        }
        .defaultLaunchBehavior(daemon.configuration.uiTest ? .presented : .suppressed)

        Settings {
            SettingsView(daemon: daemon)
        }
    }
}

extension Notification.Name {
    static let clarifyOpenEngage = Notification.Name("clarify.openEngage")
}

/// The status item's label is the one view that always exists, so it is where
/// "open the Engage window" requests from the URL scheme are turned into openWindow.
struct MenuBarLabel: View {
    @ObservedObject var daemon: Daemon
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: daemon.paused ? "checklist.unchecked" : "checklist")
            .accessibilityLabel("Clarify")
            .onReceive(NotificationCenter.default.publisher(for: .clarifyOpenEngage)) { _ in
                openWindow(id: "engage")
                bringWindowToFront { $0.title.localizedCaseInsensitiveContains("engage") }
            }
    }
}
