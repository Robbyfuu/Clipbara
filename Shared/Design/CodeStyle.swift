import SwiftUI

/// Code-colored text for cards and rows. Detection and tokens run once per clip content, then come from the cache, so
/// a card never re-runs them when its body is evaluated again.
enum CodeStyle {
    private final class Entry: Sendable {
        let text: AttributedString?
        init(_ text: AttributedString?) { self.text = text }
    }

    // Keyed by `contentHash` alone: every caller for a given hash passes the same display text (Mac: `previewText`; iOS: the first 2048 characters).
    private nonisolated(unsafe) static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        return cache
    }()

    /// `text` with code colors, or nil when it is not code. Cached under `key`, the clip's `contentHash`: each surface
    /// passes the same display text for a given hash. `text` is read only on a cache miss.
    static func attributed(_ text: @autoclosure () -> String, key: String) -> AttributedString? {
        if let entry = cache.object(forKey: key as NSString) { return entry.text }
        let text = text()
        var result: AttributedString?
        if CodeDetector.isCode(text) {
            var colored = AttributedString(text)
            for token in SyntaxHighlighter.tokens(in: text) {
                guard let lower = AttributedString.Index(token.range.lowerBound, within: colored),
                      let upper = AttributedString.Index(token.range.upperBound, within: colored) else { continue }
                colored[lower..<upper].foregroundColor = DesignTokens.Brand.code(token.kind)
            }
            result = colored
        }
        cache.setObject(Entry(result), forKey: key as NSString)
        return result
    }
}
