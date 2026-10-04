import Foundation

/// The iPhone's notice for clips that arrived from another device while Copyd was in the background.
enum ArrivalNotice {
    static let bodyLimit = 80

    /// `previews` newest first, one per clip. One clip names the device; more give the count and the newest preview.
    /// `bundle` holds the catalog; tests pass one language's `.lproj`.
    static func content(previews: [String], device: String, bundle: Bundle = .main) -> (title: String, body: String) {
        let title = previews.count == 1
            ? String(localized: "New clip from \(device)", bundle: bundle)
            : String(localized: "\(previews.count) new clips", bundle: bundle)
        let newest = previews.first ?? ""
        return (title, newest.count > bodyLimit ? newest.prefix(bodyLimit) + "\u{2026}" : newest)
    }

    /// A clip's text on one line, or its type's name when it has no text (an image).
    static func preview(type: ContentType, text: String?) -> String {
        // Cut first so a multi-MB clip is never split whole.
        let line = (type == .image ? "" : (text ?? "").prefix(600))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? type.displayName : line
    }
}
