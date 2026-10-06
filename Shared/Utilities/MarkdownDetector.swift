import Foundation

/// Whether a clip's text is Markdown, from its first 4 KB only.
enum MarkdownDetector {
    static let sampleBytes = 4096

    // ponytail: counts simple line signals, not a parser. Two notes lines starting with "- " read as Markdown, which
    // they render as anyway. Add signals here when a real clip misfires.
    /// At least two signals: `#` headings, `-`/`*`/`+`/`1.` list lines, fences, `**bold**` or `[text](url)`.
    /// One `*` or `#` in prose is not Markdown.
    static func isMarkdown(_ text: String) -> Bool {
        let sample = String(decoding: text.utf8.prefix(sampleBytes), as: UTF8.self)
        var signals = 0
        for line in sample.split(whereSeparator: \.isNewline) {
            signals += blockSignal(line) + inlineSignals(line)
            if signals >= 2 { return true }
        }
        return false
    }

    /// A fence, a heading ("# Title", up to six), or a list line ("- a", "* a", "+ a", "1. a", "1) a").
    private static func blockSignal(_ line: Substring) -> Int {
        let line = line.drop { $0 == " " || $0 == "\t" }
        if line.hasPrefix("```") { return 1 }
        var rest: Substring
        let hashes = line.prefix { $0 == "#" }.count
        if hashes > 0 {
            guard hashes <= 6 else { return 0 }
            rest = line.dropFirst(hashes)
        } else if let first = line.first, "-*+".contains(first) {
            rest = line.dropFirst()
        } else {
            let digits = line.prefix { $0.isASCII && $0.isNumber }.count
            rest = line.dropFirst(digits)
            guard (1...9).contains(digits), rest.first == "." || rest.first == ")" else { return 0 }
            rest = rest.dropFirst()
        }
        return rest.first == " " && rest.contains { !$0.isWhitespace } ? 1 : 0
    }

    /// Each `**bold**` and `[text](url)` on the line.
    private static func inlineSignals(_ line: Substring) -> Int {
        var count = 0
        var rest = line
        while let open = rest.range(of: "**") {
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "**") else { break }
            let inner = after[..<close.lowerBound]
            if let first = inner.first, let last = inner.last, !first.isWhitespace, !last.isWhitespace { count += 1 }
            rest = after[close.upperBound...]
        }
        rest = line
        while let middle = rest.range(of: "](") {
            if rest[..<middle.lowerBound].contains("["), rest[middle.upperBound...].contains(")") { count += 1 }
            rest = rest[middle.upperBound...]
        }
        return count
    }
}
