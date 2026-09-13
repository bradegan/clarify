import Foundation

public enum Prompts {
    public static func text(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Prompts"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("missing prompt \(name)")
        }
        return text
    }
}
