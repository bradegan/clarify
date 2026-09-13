import Foundation

/// The metadata block Clarify writes at the top of a reminder's notes.
/// Everything after the end marker belongs to the user and is never touched.
public struct Header: Equatable, Sendable {
    public static let startMarker = "--- clarify ---"
    public static let endMarker = "--- end ---"
    public static let knownKeys = ["kind", "context", "minutes", "energy", "area", "project", "delegated_to", "since", "reason", "recipe", "event", "outcome"]

    public var fields: [(key: String, value: String)]

    public init(fields: [(key: String, value: String)] = []) {
        self.fields = fields
    }

    public init(_ pairs: KeyValuePairs<String, String>) {
        self.fields = pairs.map { (key: $0.key, value: $0.value) }
    }

    public subscript(key: String) -> String? {
        get { fields.first { $0.key == key }?.value }
        set {
            fields.removeAll { $0.key == key }
            if let newValue { fields.append((key: key, value: newValue)) }
        }
    }

    public static func == (lhs: Header, rhs: Header) -> Bool {
        lhs.fields.map { "\($0.key)=\($0.value)" } == rhs.fields.map { "\($0.key)=\($0.value)" }
    }

    /// Splits notes into the header and the user's own text.
    public static func parse(_ notes: String?) -> (header: Header?, body: String) {
        guard let notes else { return (nil, "") }
        let lines = notes.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == startMarker }),
              let end = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker }) else {
            return (nil, notes)
        }
        var header = Header()
        for line in lines[(start + 1)..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            header.fields.append((key: key, value: value))
        }
        let before = lines[..<start]
        let after = lines[(end + 1)...]
        let body = (Array(before) + Array(after)).joined(separator: "\n")
        return (header, body.hasPrefix("\n") ? String(body.dropFirst()) : body)
    }

    /// Renders the header followed by the user's text. Values are forced to a single line.
    public func render(body: String) -> String {
        var out = [Header.startMarker]
        for field in fields {
            let value = field.value.replacingOccurrences(of: "\n", with: " ")
            out.append("\(field.key): \(value)")
        }
        out.append(Header.endMarker)
        let bodyTrimmed = body.hasPrefix("\n") ? String(body.dropFirst()) : body
        return bodyTrimmed.isEmpty ? out.joined(separator: "\n") : out.joined(separator: "\n") + "\n" + bodyTrimmed
    }

    /// Rewrites the header in `notes`, keeping the user's text.
    public func apply(to notes: String?) -> String {
        let (_, body) = Header.parse(notes)
        return render(body: body)
    }
}
