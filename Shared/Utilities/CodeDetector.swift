import Foundation

/// Whether a clip's text is source code, from its first 2 KB only.
enum CodeDetector {
    static let sampleBytes = 2048

    // ponytail: a majority-of-lines vote over simple signals, not a parser. One stray "==" or "(" in prose never flips
    // it, but a short note written like code ("SELECT the photos") can. Add signals here when a real clip misfires.
    static func isCode(_ text: String) -> Bool {
        let sample = String(decoding: text.utf8.prefix(sampleBytes), as: UTF8.self)
        let body = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("#!") || looksLikeJSON(body) { return true }
        // One token (a URL, an email, a phone number, a code from a text message) is never code.
        guard body.contains(where: \.isWhitespace) else { return false }
        let lines = body.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        return lines.filter(isCodeLine).count * 2 > lines.count
    }

    /// Starts with "{" or "[" followed by a quote, a bracket or a digit. "[draft] notes" does not.
    private static func looksLikeJSON(_ body: String) -> Bool {
        guard body.first == "{" || body.first == "[" else { return false }
        return body.dropFirst().first { !$0.isWhitespace }.map { "\"{[".contains($0) || $0.isNumber } ?? false
    }

    private static let operators = [" == ", " != ", " && ", " || ", " => ", " += ", " := ", "::", "${", "$(", "</", "/>"]

    private static func isCodeLine(_ raw: Substring) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if isListItem(line) { return false }
        if line.hasSuffix(";") || line.hasSuffix("{") || line.hasPrefix("}") || line.hasPrefix("//") || line.hasPrefix("/*") {
            return true
        }
        if operators.contains(where: { line.contains($0) }) { return true }
        let word = line.prefix { $0.isLetter || $0 == "_" }
        let keyword = !word.isEmpty && SyntaxHighlighter.isKeyword(word)
        let structured = hasCall(line) || line.contains(where: "=[{<".contains)
        if keyword && structured { return true }
        // SQL: an upper-case keyword before lower-case names ("SELECT id, name", "FROM users"), not shouting.
        if keyword, word.allSatisfy(\.isUppercase), line.dropFirst(word.count).contains(where: \.isLowercase) { return true }
        // An indented line, unless it is plain words (wrapped prose).
        let indented = raw.hasPrefix("\t") || raw.hasPrefix("  ")
        return indented && (keyword || structured)
    }

    /// "- ", "* ", "+ ", "• ", "1. " or "1) ".
    private static func isListItem(_ line: String) -> Bool {
        if ["- ", "* ", "+ ", "• "].contains(where: line.hasPrefix) { return true }
        let rest = line.drop(while: \.isNumber)
        return rest.count < line.count && (rest.hasPrefix(". ") || rest.hasPrefix(") "))
    }

    /// A "(" right after a name: `greet(`, `log(`. "call me (later)" has none.
    private static func hasCall(_ line: String) -> Bool {
        zip(line, line.dropFirst()).contains { $1 == "(" && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}
