import Foundation

enum CodeTokenKind: Sendable {
    case keyword, string, comment, number
}

typealias CodeToken = (range: Range<String.Index>, kind: CodeTokenKind)

/// Language-agnostic code tokens: one pass over the UTF-8 bytes of the first `limit` characters, so a huge clip or an
/// unterminated string or comment costs no more than `limit` characters do.
enum SyntaxHighlighter {
    /// One combined set for Swift, JS/TS, Python, Go, Rust, SQL and shell.
    static let keywords: Set<String> = [
        // Swift
        "actor", "any", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default",
        "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for",
        "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let", "mutating", "nil",
        "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "rethrows", "return",
        "self", "Self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
        "typealias", "var", "weak", "where", "while",
        // JS / TS
        "as", "const", "declare", "delete", "export", "extends", "finally", "from", "function", "implements",
        "instanceof", "interface", "keyof", "let", "namespace", "new", "null", "of", "readonly", "this", "type",
        "typeof", "undefined", "void", "yield",
        // Python
        "and", "assert", "def", "del", "elif", "except", "False", "global", "lambda", "None", "nonlocal", "not", "or",
        "pass", "raise", "True", "with",
        // Go
        "chan", "go", "goto", "package", "range", "select",
        // Rust
        "crate", "dyn", "extern", "fn", "impl", "loop", "match", "mod", "mut", "pub", "trait", "unsafe", "use",
        // SQL
        "alter", "asc", "between", "by", "create", "desc", "distinct", "drop", "exists", "group", "having", "inner",
        "insert", "into", "join", "like", "limit", "on", "order", "outer", "set", "table", "union", "update", "values",
        "when", "then", "end",
        // Shell
        "done", "echo", "esac", "fi", "local", "until",
    ]

    /// A keyword as written, or in all upper case (SQL's usual style). "Select" is not one.
    static func isKeyword<S: StringProtocol>(_ word: S) -> Bool {
        if keywords.contains(String(word)) { return true }
        return word.allSatisfy(\.isUppercase) && keywords.contains(word.lowercased())
    }

    static func tokens(in text: String, limit: Int = 2048) -> [CodeToken] {
        let utf8 = text.utf8
        let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        var tokens: [CodeToken] = []

        func at(_ index: String.Index) -> UInt8? { index < end ? utf8[index] : nil }
        func next(_ index: String.Index) -> String.Index { utf8.index(after: index) }
        func previous(_ index: String.Index) -> UInt8? { index > text.startIndex ? utf8[utf8.index(before: index)] : nil }
        /// The first line break at or after `index`, or `end`.
        func lineEnd(_ index: String.Index) -> String.Index {
            var i = index
            while let byte = at(i), !isLineBreak(byte) { i = next(i) }
            return i
        }

        var i = text.startIndex
        while let byte = at(i) {
            let following = at(next(i))
            let start = i
            switch byte {
            case UInt8(ascii: "/") where following == UInt8(ascii: "/") && previous(i) != UInt8(ascii: ":"),
                 UInt8(ascii: "#") where isSpaceOrStart(previous(i)) && opensHashComment(following),
                 UInt8(ascii: "-") where following == UInt8(ascii: "-") && isSpaceOrStart(previous(i))
                     && opensHashComment(at(next(next(i)))):
                // "//" (not a URL's "://"), "# " (not "#if" or "#fff"), and "-- " (not "--flag" or "x--").
                i = lineEnd(i)
                tokens.append((start..<i, .comment))
            case UInt8(ascii: "/") where following == UInt8(ascii: "*"):
                i = next(next(i))
                while let b = at(i) {
                    i = next(i)
                    if b == UInt8(ascii: "*"), at(i) == UInt8(ascii: "/") { i = next(i); break }
                }
                tokens.append((start..<i, .comment))
            case UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`"):
                // A backslash skips the next byte. ' and " end at the line break when unterminated; ` may span lines.
                i = next(i)
                while let b = at(i) {
                    if b == byte { i = next(i); break }
                    if isLineBreak(b), byte != UInt8(ascii: "`") { break }
                    i = next(i)
                    if b == UInt8(ascii: "\\"), at(i) != nil { i = next(i) }
                }
                tokens.append((start..<i, .string))
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                // Identifiers swallow their own digits, so a digit here starts a number: 42, 3.14, 0x1F, 1_000.
                while let b = at(i), isWordByte(b) || (b == UInt8(ascii: ".") && isDigit(at(next(i)))) { i = next(i) }
                tokens.append((start..<i, .number))
            case _ where isWordByte(byte):
                while let b = at(i), isWordByte(b) { i = next(i) }
                if isKeyword(text[start..<i]) { tokens.append((start..<i, .keyword)) }
            default:
                i = next(i)
            }
        }
        return tokens
    }

    private static func isLineBreak(_ byte: UInt8) -> Bool { byte == 0x0A || byte == 0x0D }

    private static func isDigit(_ byte: UInt8?) -> Bool { byte.map { (0x30...0x39).contains($0) } ?? false }

    /// Letters, digits, "_" and every non-ASCII byte, so a word never splits inside a multi-byte character.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 0x80 || byte == UInt8(ascii: "_") || isDigit(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
    }

    private static func isSpaceOrStart(_ byte: UInt8?) -> Bool {
        byte.map { $0 == 0x20 || $0 == 0x09 || isLineBreak($0) } ?? true
    }

    /// What may follow "#" or "--" for it to open a comment: a space, a line end, or "#!" / "##".
    private static func opensHashComment(_ byte: UInt8?) -> Bool {
        byte.map { isSpaceOrStart($0) || $0 == UInt8(ascii: "!") || $0 == UInt8(ascii: "#") } ?? true
    }
}
