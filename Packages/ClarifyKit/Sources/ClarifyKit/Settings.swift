import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case onDevice = "on_device"
    case endpoint
    case openrouter
}

/// User settings. The app persists this as JSON; the endpoint key lives in Keychain.
public struct Settings: Codable, Equatable, Sendable {
    public var provider: Provider = .onDevice
    public var endpointURL: String = "http://127.0.0.1:1234"
    public var endpointModel: String = ""
    public var openrouterModel: String = "anthropic/claude-sonnet-5"
    public var endpointTimeout: TimeInterval = 120
    public var autoRunRecipes: Bool = true
    public var autoCloseWaiting: Bool = false
    public var contexts: [String] = Contexts.defaults
    public var weeklyReviewWeekday: Int = 6
    public var weeklyReviewHour: Int = 16
    public var dailySweepHour: Int = 7
    public var mailWatchIntervalMinutes: Int = 10
    public var twoMinuteThreshold: Int = 2
    public var useAgentLoop: Bool = true
    public var webSearch: Bool = true

    public init() {}
}
