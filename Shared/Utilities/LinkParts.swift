import Foundation

/// Splits a link into a display host (no leading "www.") and the path plus query.
enum LinkParts {
    static func split(_ text: String) -> (host: String, rest: String)? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty else { return nil }
        let rest = parts.path + (parts.query.map { "?" + $0 } ?? "")
        return (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host, rest == "/" ? "" : rest)
    }
}
