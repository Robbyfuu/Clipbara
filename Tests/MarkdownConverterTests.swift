import AppKit
import SwiftUI
import XCTest

/// Review focus 5: nested lists and entities convert, and malformed HTML never crashes.
final class MarkdownConverterTests: XCTestCase {
    private func md(_ html: String) -> String { MarkdownConverter.markdown(fromHTML: html) }

    // MARK: HTML

    func testHeadingsParagraphsAndEmphasis() {
        XCTAssertEqual(md("<h1>Title</h1><p>Body <b>bold</b> and <em>soft</em> and <strong><i>both</i></strong></p><h3>Small</h3>"),
                       "# Title\n\nBody **bold** and *soft* and ***both***\n\n### Small")
    }

    func testSourceWhitespaceCollapsesAndEmphasisKeepsItsSpacesOutside() {
        XCTAssertEqual(md("<p>\n  Some   text <b>bold </b>next\n</p>\n\n<p>Second</p>"), "Some text **bold** next\n\nSecond")
    }

    func testNestedLists() {
        let html = """
            <ul>
              <li>One
                <ul><li>One A</li><li>One B</li></ul>
              </li>
              <li>Two</li>
            </ul>
            <ol><li>First</li><li>Second<ol><li>Inner</li></ol></li></ol>
            """
        XCTAssertEqual(md(html), "- One\n  - One A\n  - One B\n- Two\n\n1. First\n2. Second\n   1. Inner")
    }

    func testLinks() {
        XCTAssertEqual(md(#"<p>See <a href="https://example.com/a?b=1&amp;c=2">the site</a>.</p>"#),
                       "See [the site](https://example.com/a?b=1&c=2).")
        XCTAssertEqual(md("<a name=\"top\">Anchor</a> only"), "Anchor only", "no href, no link")
        XCTAssertEqual(md("<a href='https://e.com'></a>Empty"), "Empty", "no text, no link")
    }

    func testEntities() {
        XCTAssertEqual(md("<p>Tom &amp; Jerry &lt;3 &quot;hi&quot; &#39;x&#39; &#x1F600; caf&#233;&nbsp;ok &hellip; &bogus; AT&T</p>"),
                       "Tom & Jerry <3 \"hi\" 'x' 😀 café ok … &bogus; AT&T")
    }

    func testCodeAndPre() {
        XCTAssertEqual(md("<p>Run <code>ls -la</code> now</p><pre><code>if a &lt; b {\n    go()\n}\n</code></pre>"),
                       "Run `ls -la` now\n\n```\nif a < b {\n    go()\n}\n```")
    }

    func testBreaksAndQuotes() {
        XCTAssertEqual(md("<p>one<br>two<br/>three</p><blockquote><p>Quoted</p></blockquote>"), "one\ntwo\nthree\n\n> Quoted")
    }

    /// What a browser puts on the Mac pasteboard: a meta tag, styles and spans.
    func testPasteboardHTMLDropsStylesAndUnknownTags() {
        XCTAssertEqual(md("<meta charset='utf-8'><style>p { color: red }</style><span style=\"font-weight: 700\">Hello</span> <font>world</font><script>alert(1)</script>"),
                       "Hello world")
    }

    func testMalformedHTMLNeverCrashesAndKeepsTheText() {
        let open = md("<p>Open <b>bold <i>both</p><li>stray")
        for word in ["Open", "bold", "both", "stray"] { XCTAssertTrue(open.contains(word), open) }
        XCTAssertEqual(md("</ul></li></ol></b>text"), "text")
        XCTAssertEqual(md("a < b and c > d"), "a < b and c > d")
        XCTAssertTrue(md("<a href=\"x\">no close").contains("no close"))
        for html in ["<p class=\"x", "<<>>", "<", "&", "", "&#xFFFFFFFF; &#0; &#; &#x;", "<!-- open comment", "<a href=>x</a>",
                     "<pre>never closed", "<ul><li>a", String(repeating: "<ul><li>deep", count: 300),
                     String(repeating: "<b>", count: 1_000)] {
            _ = md(html)
        }
    }

    // MARK: Attributed string (RTF)

    private func font(_ size: CGFloat = 12, bold: Bool = false, italic: Bool = false) -> NSFont {
        NSFont(name: ["Helvetica", "Helvetica-Oblique", "Helvetica-Bold", "Helvetica-BoldOblique"][(bold ? 2 : 0) + (italic ? 1 : 0)],
               size: size)!
    }

    private func text(_ parts: [(String, [NSAttributedString.Key: Any])]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (string, attributes) in parts {
            result.append(NSAttributedString(string: string, attributes: [.font: font()].merging(attributes) { $1 }))
        }
        return result
    }

    /// Through RTF and back, as a clip's data is read.
    private func viaRTF(_ string: NSAttributedString) throws -> NSAttributedString {
        let data = try string.data(from: NSRange(location: 0, length: string.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                      documentAttributes: nil)
    }

    func testBoldAndItalic() throws {
        let string = text([("Plain ", [:]), ("bold ", [.font: font(bold: true)]), ("and ", [:]),
                           ("soft", [.font: font(italic: true)]), (" and ", [:]), ("both", [.font: font(bold: true, italic: true)])])
        XCTAssertEqual(MarkdownConverter.markdown(from: string), "Plain **bold** and *soft* and ***both***")
        XCTAssertEqual(MarkdownConverter.markdown(from: try viaRTF(string)), "Plain **bold** and *soft* and ***both***")
    }

    func testLink() throws {
        let string = text([("See ", [:]), ("docs", [.link: URL(string: "https://example.com/docs")!]), (" or ", [:]),
                           ("this", [.link: "https://example.com/this"]), (".", [:])])
        XCTAssertEqual(MarkdownConverter.markdown(from: string), "See [docs](https://example.com/docs) or [this](https://example.com/this).")
    }

    func testListsThroughRTF() throws {
        let disc = NSTextList(markerFormat: .disc, options: 0)
        let decimal = NSTextList(markerFormat: .decimal, options: 0)
        func style(_ lists: [NSTextList]) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.textLists = lists
            return style
        }
        // The marker text, as the Mac's text system types it.
        let string = text([("\t•\tOne\n", [.paragraphStyle: style([disc])]),
                           ("\t◦\tInner\n", [.paragraphStyle: style([disc, NSTextList(markerFormat: .circle, options: 0)])]),
                           ("\t•\tTwo\n", [.paragraphStyle: style([disc])]),
                           ("Between\n", [:]),
                           ("\t1.\tFirst\n", [.paragraphStyle: style([decimal])]),
                           ("\t2.\tSecond\n", [.paragraphStyle: style([decimal])])])
        let expected = "- One\n  - Inner\n- Two\n\nBetween\n\n1. First\n2. Second"
        XCTAssertEqual(MarkdownConverter.markdown(from: string), expected)
        XCTAssertEqual(MarkdownConverter.markdown(from: try viaRTF(string)), expected)
    }

    /// The body size is the most common one: at least 1.6× is `#`, at least 1.3× is `##`.
    func testHeadingsBySize() throws {
        let string = text([("Title\n", [.font: font(24, bold: true)]), ("Sub\n", [.font: font(16)]),
                           ("Body text that is long\n", [:]), ("Slightly big\n", [.font: font(14)]), ("More body", [:])])
        let expected = "# Title\n\n## Sub\n\nBody text that is long\n\nSlightly big\n\nMore body"
        XCTAssertEqual(MarkdownConverter.markdown(from: string), expected)
        XCTAssertEqual(MarkdownConverter.markdown(from: try viaRTF(string)), expected)
    }

    func testPlainAndEmptyAttributedStrings() {
        XCTAssertEqual(MarkdownConverter.markdown(from: NSAttributedString(string: "a\n\n\nb\n")), "a\n\nb")
        XCTAssertEqual(MarkdownConverter.markdown(from: NSAttributedString()), "")
    }

    // MARK: Markdown to formatted text

    func testFormattedTextFromMarkdown() throws {
        let source = "# Title\n\nSome **bold** and *it* with [link](https://e.com)\n\n- one\n- two\n  - inner\n\n1. a\n2. b\n\n```\ncode\n```"
        let string = try XCTUnwrap(MarkdownConverter.attributed(fromMarkdown: source))
        XCTAssertEqual(string.string, "Title\nSome bold and it with link\n• one\n• two\n    • inner\n1. a\n2. b\ncode")
        let ns = string.string as NSString
        func font(of word: String) -> NSFont? {
            string.attribute(.font, at: ns.range(of: word).location, effectiveRange: nil) as? NSFont
        }
        let body = try XCTUnwrap(font(of: "Some"))
        XCTAssertGreaterThan(try XCTUnwrap(font(of: "Title")).pointSize, body.pointSize)
        XCTAssertTrue(try XCTUnwrap(font(of: "Title")).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try XCTUnwrap(font(of: "bold")).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try XCTUnwrap(font(of: "it ")).fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(body.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try XCTUnwrap(font(of: "code")).isFixedPitch)
        XCTAssertEqual(string.attribute(.link, at: ns.range(of: "link").location, effectiveRange: nil) as? URL,
                       URL(string: "https://e.com"))
    }

    /// Formatted text from Markdown reads back as the same Markdown.
    func testRoundTrip() throws {
        let source = "# Title\n\nSome **bold** and *it* with [link](https://e.com)"
        XCTAssertEqual(MarkdownConverter.markdown(from: try XCTUnwrap(MarkdownConverter.attributed(fromMarkdown: source))), source)
    }

    // MARK: Cards and rows

    /// Line by line: headings lose their `#`, bullets show, fences go, and inline styles stay as intents.
    func testCardRendering() throws {
        let source = "# Notes\n\n- **milk**\n* eggs\n1. one\n  - nested\n```\nlet x = 1\n```\nend"
        let shown = try XCTUnwrap(MarkdownStyle.attributed(source, key: UUID().uuidString, size: 13))
        XCTAssertEqual(String(shown.characters), "Notes\n\n• milk\n• eggs\n1. one\n  • nested\nlet x = 1\nend")
        let milk = try XCTUnwrap(shown.range(of: "milk"))
        XCTAssertEqual(shown[milk].inlinePresentationIntent, .stronglyEmphasized)
        XCTAssertNotNil(shown[try XCTUnwrap(shown.range(of: "Notes"))][AttributeScopes.SwiftUIAttributes.FontAttribute.self])
        XCTAssertEqual(shown[try XCTUnwrap(shown.range(of: "let x"))].inlinePresentationIntent, .code)
        // A row's font and color would hide inline code and links: they carry their own.
        let inline = try XCTUnwrap(MarkdownStyle.attributed("- Run `ls` now\n- See [docs](https://e.com)", key: UUID().uuidString, size: 13))
        XCTAssertEqual(inline[try XCTUnwrap(inline.range(of: "ls"))][AttributeScopes.SwiftUIAttributes.FontAttribute.self],
                       .system(size: 13, design: .monospaced))
        XCTAssertEqual(inline[try XCTUnwrap(inline.range(of: "docs"))][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self],
                       .single)
    }

    func testProseIsNotRenderedAsMarkdown() {
        XCTAssertNil(MarkdownStyle.attributed("Use a * for wildcards", key: UUID().uuidString, size: 13))
    }

    func testEmptyMarkdownHasNoFormattedText() {
        XCTAssertNil(MarkdownConverter.attributed(fromMarkdown: ""))
        XCTAssertNil(MarkdownConverter.attributed(fromMarkdown: " \n"))
    }
}
