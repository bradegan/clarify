import Foundation

/// A tool the agent may call. `mutating` tools never act directly; they queue an
/// Approve reminder and return a note to the model.
public struct ToolSpec: Sendable {
    public let name: String
    public let description: String
    public let parametersJSONSchema: String
    public let mutating: Bool
    public init(name: String, description: String, parametersJSONSchema: String, mutating: Bool) {
        self.name = name; self.description = description; self.parametersJSONSchema = parametersJSONSchema; self.mutating = mutating
    }
}

public struct ToolInvocation: Sendable, Equatable {
    public let id: String
    public let name: String
    public let arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
    public func arg(_ key: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let s = obj[key] as? String { return s }
        if let v = obj[key] { return String(describing: v) }
        return nil
    }
}

public struct ChatMessage: Sendable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    public var toolCallID: String?
    public var toolCalls: [ToolInvocation]
    public init(role: Role, content: String, toolCallID: String? = nil, toolCalls: [ToolInvocation] = []) {
        self.role = role; self.content = content; self.toolCallID = toolCallID; self.toolCalls = toolCalls
    }
}

public struct AssistantTurn: Sendable {
    public var text: String
    public var toolCalls: [ToolInvocation]
    public init(text: String, toolCalls: [ToolInvocation]) { self.text = text; self.toolCalls = toolCalls }
}

/// A model that can hold a tool-calling conversation. The endpoint model conforms;
/// on-device Foundation Models does not, so the loop is used only with an endpoint.
public protocol ToolChatModel: Sendable {
    var name: String { get }
    func converse(system: String, messages: [ChatMessage], tools: [ToolSpec]) async throws -> AssistantTurn
}

extension EndpointLanguageModel: ToolChatModel {
    public func converse(system: String, messages: [ChatMessage], tools: [ToolSpec]) async throws -> AssistantTurn {
        var wire: [[String: Any]] = [["role": "system", "content": system]]
        for m in messages {
            switch m.role {
            case .assistant where !m.toolCalls.isEmpty:
                wire.append(["role": "assistant", "content": m.content,
                             "tool_calls": m.toolCalls.map { ["id": $0.id, "type": "function",
                                 "function": ["name": $0.name, "arguments": $0.arguments]] }])
            case .tool:
                wire.append(["role": "tool", "tool_call_id": m.toolCallID ?? "", "content": m.content])
            default:
                wire.append(["role": m.role.rawValue, "content": m.content])
            }
        }
        let toolsJSON: [[String: Any]] = try tools.map { spec in
            ["type": "function", "function": ["name": spec.name, "description": spec.description,
             "parameters": try JSONSerialization.jsonObject(with: Data(spec.parametersJSONSchema.utf8))]]
        }
        var request = authorized(baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "temperature": 0, "messages": wire, "tools": toolsJSON, "tool_choice": "auto"])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        if [401, 402, 403].contains(status) { throw ModelError.authFailed(String(bodyText.prefix(200))) }
        guard (200..<300).contains(status) else { throw ModelError.http(status, String(bodyText.prefix(300))) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { throw ModelError.emptyResponse }
        let text = (message["content"] as? String) ?? ""
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).compactMap { tc -> ToolInvocation? in
            guard let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
            return ToolInvocation(id: tc["id"] as? String ?? UUID().uuidString, name: name,
                                  arguments: fn["arguments"] as? String ?? "{}")
        }
        return AssistantTurn(text: text, toolCalls: calls)
    }
}
