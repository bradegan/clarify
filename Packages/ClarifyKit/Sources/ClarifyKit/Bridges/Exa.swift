import Foundation

/// Exa web search. Uses the /answer endpoint, which returns a grounded answer
/// with citations, so the agent gets a fact and its sources in one call.
public struct ExaClient: WebSearchBridge {
    let apiKey: String
    let session: URLSession
    let endpoint = URL(string: "https://api.exa.ai/answer")!

    public init(apiKey: String, session: URLSession = .shared) { self.apiKey = apiKey; self.session = session }

    public func answer(_ query: String) async throws -> WebAnswer {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "text": false])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw ModelError.authFailed("Exa rejected the key") }
        guard (200..<300).contains(status) else { throw ModelError.http(status, String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ModelError.emptyResponse }
        let answer = (json["answer"] as? String) ?? ""
        let sources = (json["citations"] as? [[String: Any]] ?? []).prefix(4).map {
            WebSource(title: ($0["title"] as? String) ?? "", url: ($0["url"] as? String) ?? "")
        }
        return WebAnswer(answer: answer, sources: Array(sources))
    }
}
