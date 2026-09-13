import Foundation

/// File search through Spotlight's command line, scoped to the home folder,
/// newest first, hidden and Library paths skipped.
public struct SpotlightFiles: FilesBridge {
    let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public func find(query: String, limit: Int) async throws -> [URL] {
        let words = query.split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return [] }
        let clause = words.map { "kMDItemFSName == \"*\($0.replacingOccurrences(of: "\"", with: ""))*\"c" }.joined(separator: " && ")
        let output = try await run("/usr/bin/mdfind", ["-onlyin", home.path, clause])
        let urls = output.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
            .filter { url in
                let rel = url.path.dropFirst(home.path.count)
                return !rel.contains("/Library/") && !rel.split(separator: "/").contains { $0.hasPrefix(".") } && !rel.contains("/node_modules/")
            }
        let dated = urls.map { url -> (URL, Date) in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url, d)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            p.terminationHandler = { _ in
                cont.resume(returning: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}
