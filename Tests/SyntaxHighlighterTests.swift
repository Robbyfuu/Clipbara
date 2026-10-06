import XCTest

final class SyntaxHighlighterTests: XCTestCase {
    /// "text:kind" for each token, in order.
    private func describe(_ text: String, limit: Int = 2048) -> [String] {
        SyntaxHighlighter.tokens(in: text, limit: limit).map { "\(text[$0.range]):\($0.kind)" }
    }

    func testEachKind() {
        let text = "let n = 42 // answer\nname = \"Copyd\" # note\n/* block */ x -- sql"
        XCTAssertEqual(describe(text), [
            "let:keyword", "42:number", "// answer:comment",
            "\"Copyd\":string", "# note:comment",
            "/* block */:comment", "-- sql:comment",
        ])
    }

    func testOneKeywordSetForEveryLanguage() {
        XCTAssertEqual(describe("fn main() { def go fi Self }"), ["fn:keyword", "def:keyword", "go:keyword", "fi:keyword", "Self:keyword"])
        // SQL is matched in upper case too, but a capitalized word is not a keyword.
        XCTAssertEqual(describe("SELECT id FROM users WHERE n = 0x1F; Select"),
                       ["SELECT:keyword", "FROM:keyword", "WHERE:keyword", "0x1F:number"])
    }

    func testNestedAndEscapedQuotes() {
        let text = #"say("it's \"fine\"", 'a "b" c', `t ${x}`)"#
        XCTAssertEqual(describe(text), [#""it's \"fine\"":string"#, #"'a "b" c':string"#, "`t ${x}`:string"])
    }

    func testCommentMarkersInStringsFlagsAndDirectives() {
        let text = "let url = \"https://copyd.app\" // site\nrg --files # list\n#if DEBUG\ncurl https://x.com"
        XCTAssertEqual(describe(text), [
            "let:keyword", "\"https://copyd.app\":string", "// site:comment", "# list:comment", "if:keyword",
        ])
    }

    func testUnterminatedStringStopsAtLineEnd() {
        XCTAssertEqual(describe("x = \"open\nreturn 1"), ["\"open:string", "return:keyword", "1:number"])
    }

    func testTokensStayOnCharacterBoundaries() {
        // An emoji with a skin tone, a combining mark right after a closing quote, a flag after a number and after a
        // quote, and a CRLF after an unterminated string.
        let text = "let 👍🏽 = \"ok\"\u{301} + 'a'🇨🇱 // 🇨🇱 flag\nvar n = 42🇨🇱\nx = \"open\r\nreturn"
        let attributed = AttributedString(text)
        let boundaries = Set(text.indices.map { text.utf8.distance(from: text.startIndex, to: $0) } + [text.utf8.count])
        let tokens = SyntaxHighlighter.tokens(in: text)
        XCTAssertFalse(tokens.isEmpty)
        for token in tokens {
            _ = text[token.range]
            for bound in [token.range.lowerBound, token.range.upperBound] {
                XCTAssertTrue(boundaries.contains(text.utf8.distance(from: text.startIndex, to: bound)), "\(text[token.range])")
                XCTAssertNotNil(AttributedString.Index(bound, within: attributed), "\(text[token.range])")
            }
        }
    }

    func testLimitBoundsScalarsNotOnlyCharacters() {
        // One Character made of 200,000 combining marks: the work stops near `limit` scalars, not at its end.
        let text = "\"a" + String(repeating: "\u{301}", count: 200_000)
        let tokens = SyntaxHighlighter.tokens(in: text)
        XCTAssertLessThanOrEqual(tokens.map { text.utf8.distance(from: text.startIndex, to: $0.range.upperBound) }.max() ?? 0,
                                 4 * 2048)
    }

    func testLimitAndUnterminated() {
        let filler = String(repeating: "a", count: 200_000)
        for opener in ["\"", "'", "`", "/*"] {
            let text = opener + filler
            var tokens: [CodeToken] = []
            let elapsed = ContinuousClock().measure { tokens = SyntaxHighlighter.tokens(in: text) }
            XCTAssertLessThan(elapsed, .milliseconds(50), opener)
            XCTAssertEqual(tokens.count, 1, opener)
            // 2048 scalars read; the last Character before the cut may continue past it, so it is left out.
            XCTAssertEqual(tokens.first.map { text.unicodeScalars.distance(from: text.startIndex, to: $0.range.upperBound) }, 2047, opener)
        }
        XCTAssertEqual(describe("let x = 1; var y = 2", limit: 5), ["let:keyword"])
    }
}
