import SwiftUI
import ClarifyKit

struct SettingsView: View {
    @ObservedObject var daemon: Daemon
    @State private var apiKey = Keychain.read() ?? ""
    @State private var exaKey = Keychain.read(account: "exa-key") ?? ""
    @State private var contextsText = ""

    var body: some View {
        Form {
            Section("Model") {
                Picker("Provider", selection: $daemon.settings.provider) {
                    Text("On-device (Apple Intelligence)").tag(Provider.onDevice)
                    Text("OpenRouter").tag(Provider.openrouter)
                    Text("OpenAI-compatible endpoint").tag(Provider.endpoint)
                }
                switch daemon.settings.provider {
                case .openrouter:
                    TextField("Model", text: $daemon.settings.openrouterModel, prompt: Text("anthropic/claude-sonnet-5"))
                    SecureField("OpenRouter API key", text: $apiKey).onSubmit { daemon.setEndpointKey(apiKey) }
                    Button("Save key") { daemon.setEndpointKey(apiKey) }
                    Text("Routed through OpenRouter. The agent loop uses this model's tool calling.").font(.caption).foregroundStyle(.secondary)
                case .endpoint:
                    TextField("Base URL", text: $daemon.settings.endpointURL, prompt: Text("http://127.0.0.1:1234"))
                    TextField("Model", text: $daemon.settings.endpointModel, prompt: Text("qwen3.8-27b-mlx"))
                    SecureField("API key", text: $apiKey).onSubmit { daemon.setEndpointKey(apiKey) }
                    Button("Save key") { daemon.setEndpointKey(apiKey) }
                    Stepper("Timeout: \(Int(daemon.settings.endpointTimeout)) s", value: $daemon.settings.endpointTimeout, in: 10...600, step: 10)
                case .onDevice:
                    if case .failure(let e) = FoundationLanguageModel.availability() {
                        Text(e.localizedDescription).foregroundStyle(.red)
                    }
                    Text("On-device does the two-minute tasks with the simpler recipe path, not the tool loop.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Web search (Exa)") {
                Toggle("Let the agent search the web", isOn: $daemon.settings.webSearch)
                SecureField("Exa API key", text: $exaKey).onSubmit { daemon.setExaKey(exaKey) }
                Button("Save Exa key") { daemon.setExaKey(exaKey) }
                Text("Adds a web_search tool the agent can chain, e.g. find a business's number, then draft the call reminder.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Toggle("Do two-minute tasks automatically (drafts still need approval)", isOn: $daemon.settings.autoRunRecipes)
                Toggle("Use the agentic tool loop when the model supports it", isOn: $daemon.settings.useAgentLoop)
                Toggle("Close Waiting For items from Mail without asking", isOn: $daemon.settings.autoCloseWaiting)
                Stepper("Two-minute threshold: \(daemon.settings.twoMinuteThreshold) min", value: $daemon.settings.twoMinuteThreshold, in: 1...15)
                TextField("Contexts", text: $contextsText, prompt: Text("@computer @phone @home"))
                    .onSubmit { daemon.settings.contexts = contextsText.split(separator: " ").map(String.init).filter { $0.hasPrefix("@") } }
            }
            Section("Schedule") {
                Picker("Weekly review day", selection: $daemon.settings.weeklyReviewWeekday) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
                Stepper("Weekly review hour: \(daemon.settings.weeklyReviewHour):00", value: $daemon.settings.weeklyReviewHour, in: 0...23)
                Stepper("Daily sweep hour: \(daemon.settings.dailySweepHour):00", value: $daemon.settings.dailySweepHour, in: 0...23)
                Stepper("Check Mail every \(daemon.settings.mailWatchIntervalMinutes) min", value: $daemon.settings.mailWatchIntervalMinutes, in: 1...120)
            }
            Section("System") {
                Toggle("Launch at login", isOn: Binding(get: { daemon.launchAtLogin }, set: { daemon.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear { contextsText = daemon.settings.contexts.joined(separator: " ") }
    }
}
