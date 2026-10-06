import SwiftUI

/// Markdown shown formatted in cards and rows. Detection and parsing run once per clip content, then come from the
/// cache, as `CodeStyle` does.
enum MarkdownStyle {
    private final class Entry: Sendable {
        let text: AttributedString?
        init(_ text: AttributedString?) { self.text = text }
    }

    // Keyed by `contentHash` alone: every caller for a given hash passes the same display text.
    private nonisolated(unsafe) static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 300
        return cache
    }()

    /// `text` formatted, or nil when it is not Markdown. Cached under `key`, the clip's `contentHash`. `size` is the
    /// view's font size: headings are bold and 2 pt larger.
    static func attributed(_ text: @autoclosure () -> String, key: String, size: CGFloat) -> AttributedString? {
        if let entry = cache.object(forKey: key as NSString) { return entry.text }
        let text = text()
        let result = MarkdownDetector.isMarkdown(text) ? render(text, size: size) : nil
        cache.setObject(Entry(result), forKey: key as NSString)
        return result
    }

    /// Line by line: a heading drops its `#`, a bullet shows as "•", fence lines go and their code is monospaced, and
    /// each line's inline bold, italic, code and links are parsed.
    private static func render(_ text: String, size: CGFloat) -> AttributedString {
        var lines: [AttributedString] = []
        var fenced = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let content = line.drop { $0 == " " || $0 == "\t" }
            let indent = String(line.prefix(line.count - content.count))
            if content.hasPrefix("```") {
                fenced.toggle()
                continue
            }
            if fenced {
                var code = AttributedString(String(line))
                code.inlinePresentationIntent = .code
                lines.append(code)
                continue
            }
            let hashes = content.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), content.dropFirst(hashes).first == " " {
                var heading = inline(content.dropFirst(hashes + 1))
                heading[AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(size: size + 2, weight: .bold)
                lines.append(heading)
            } else if let first = content.first, "-*+".contains(first), content.dropFirst().first == " " {
                lines.append(AttributedString(indent + "• ") + inline(content.dropFirst(2)))
            } else {
                // Numbered items stay as typed: inline-only parsing leaves "1. " alone.
                lines.append(inline(line))
            }
        }
        var out = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { out += AttributedString("\n") }
            out += line
        }
        // The view's font and color would hide inline code and links: code gets a monospaced font, links an underline.
        // A link is shown, never followed: a click on the card picks it, never opens a browser.
        for run in out.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                out[run.range][AttributeScopes.SwiftUIAttributes.FontAttribute.self] = .system(size: size, design: .monospaced)
            }
            if run.link != nil {
                out[run.range][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
                out[run.range].link = nil
            }
        }
        return out
    }

    private static func inline(_ text: Substring) -> AttributedString {
        (try? AttributedString(markdown: String(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(String(text))
    }
}
