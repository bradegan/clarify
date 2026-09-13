import Foundation

/// Any OpenAI-compatible chat completions endpoint. Asks for a strict JSON
/// schema, reads the answer from `content` or, when that is empty, from
/// `reasoning_content`, decodes into the typed output, and retries once with
/// the validation error when the first answer is rejected.
public struct EndpointLanguageModel: LanguageModel {
    public let name: String
    let baseURL: URL
    let apiKey: String?
    let model: String
    let timeout: TimeInterval
    let session: URLSession
    let extraHeaders: [String: String]

    public init(baseURL: URL, apiKey: String?, model: String, timeout: TimeInterval = 120,
                extraHeaders: [String: String] = [:], session: URLSession = .shared) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.model = model; self.timeout = timeout
        self.extraHeaders = extraHeaders; self.session = session
        self.name = "\(baseURL.host ?? baseURL.absoluteString) \(model)"
    }

    func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        return request
    }

    public func respond<T: ClarifyOutput>(instructions: String, input: String, as type: T.Type) async throws -> T {
        var messages: [[String: String]] = [["role": "system", "content": instructions], ["role": "user", "content": input]]
        var lastError: Error?
        for attempt in 0..<2 {
            let text = try await complete(messages: messages, schema: T.self)
            do {
                let value = try JSONDecoder().decode(T.self, from: Data(EndpointLanguageModel.extractJSON(text).utf8))
                try value.validate()
                return value
            } catch {
                lastError = error
                guard attempt == 0 else { break }
                messages.append(["role": "assistant", "content": text])
                messages.append(["role": "user", "content": "That answer was rejected: \(error.localizedDescription). Reply again with only the JSON object."])
            }
        }
        throw ModelError.invalidOutput(lastError?.localizedDescription ?? "unknown")
    }

    func complete<T: ClarifyOutput>(messages: [[String: String]], schema: T.Type) async throws -> String {
        var request = authorized(baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        let schemaObject = try JSONSerialization.jsonObject(with: Data(T.jsonSchema.utf8))
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": messages,
            "response_format": ["type": "json_schema", "json_schema": ["name": T.schemaName, "strict": true, "schema": schemaObject]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        if status == 401 || status == 402 || status == 403 { throw ModelError.authFailed(String(bodyText.prefix(200))) }
        guard (200..<300).contains(status) else { throw ModelError.http(status, String(bodyText.prefix(200))) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { throw ModelError.emptyResponse }
        let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !content.isEmpty { return content }
        let reasoning = ((message["reasoning_content"] ?? message["reasoning"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !reasoning.isEmpty { return reasoning }
        throw ModelError.emptyResponse
    }

    /// Pulls the first balanced JSON object out of text that may carry fences or prose.
    static func extractJSON(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{") else { return text }
        var depth = 0; var inString = false; var escape = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escape { escape = false } else if c == "\\" { escape = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return String(text[start...i]) } }
            i = text.index(after: i)
        }
        return String(text[start...])
    }
}
