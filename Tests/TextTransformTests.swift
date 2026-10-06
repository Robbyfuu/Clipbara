import AppKit
import SwiftData
import XCTest

/// Review focus 3: transforms never crash on odd input (empty, emoji, CRLF, giant or deep JSON).
final class TextTransformTests: XCTestCase {
    private func apply(_ transform: TextTransform, _ text: String) -> String? { transform.apply(to: text) }

    // MARK: Case

    func testCaseTransforms() {
        XCTAssertEqual(apply(.upper, "héllo wörld ß"), "HÉLLO WÖRLD SS")
        XCTAssertEqual(apply(.lower, "HÉLLO Wörld"), "héllo wörld")
        XCTAssertEqual(apply(.title, "hello WORLD, it's me"), "Hello World, It's Me")
    }

    func testCaseKeepsEmojiAndCRLF() {
        XCTAssertEqual(apply(.upper, "👍🏽 ok\r\nfine 🇨🇱"), "👍🏽 OK\r\nFINE 🇨🇱")
        XCTAssertEqual(apply(.title, "hello 👋 world"), "Hello 👋 World")
    }

    func testCaseDoesNotApplyWhenNothingChanges() {
        XCTAssertNil(apply(.upper, "HELLO 123"))
        XCTAssertNil(apply(.lower, "hello 123"))
        XCTAssertNil(apply(.title, "Hello World"))
        XCTAssertNil(apply(.upper, "12345 🎉"), "no letters")
    }

    // MARK: Trim

    func testTrimEachLineAndBlankLinesAtTheEnds() {
        XCTAssertEqual(apply(.trim, "\n\n  first  \n\n\t second\t\n  \n"), "first\n\nsecond")
    }

    func testTrimKeepsCRLF() {
        XCTAssertEqual(apply(.trim, "  a  \r\n\r\n b \r\n"), "a\r\n\r\nb")
    }

    func testTrimKeepsEachLinesOwnTerminator() {
        XCTAssertEqual(apply(.trim, " a \r\nb \n c\r\n\n"), "a\r\nb\nc")
    }

    func testTrimKeepsALoneCarriageReturn() {
        XCTAssertEqual(apply(.trim, " a \r b "), "a\rb")
    }

    func testTrimKeepsLineAndParagraphSeparators() {
        XCTAssertEqual(apply(.trim, " a \u{2028} b \u{2029}c "), "a\u{2028}b\u{2029}c")
    }

    func testTrimDoesNotApplyToTidyOrBlankText() {
        XCTAssertNil(apply(.trim, "a\nb"))
        XCTAssertNil(apply(.trim, " \n\t\r\n "), "nothing left to paste")
    }

    // MARK: Plain

    func testPlainReturnsTheText() {
        XCTAssertEqual(apply(.plain, "Bold\ttext"), "Bold\ttext")
    }

    // MARK: Empty input

    func testEmptyInputNeverApplies() {
        for transform in TextTransform.allCases {
            XCTAssertNil(apply(transform, ""), "\(transform)")
        }
        XCTAssertEqual(TextTransform.applicable(to: "", type: .plainText), [])
    }

    // MARK: Clean link

    func testCleanLinkRemovesTrackingAndKeepsTheRest() {
        XCTAssertEqual(apply(.cleanLink, "https://shop.example/p/7?utm_source=nl&id=42&fbclid=Ab1&color=red#reviews"),
                       "https://shop.example/p/7?id=42&color=red#reviews")
    }

    func testCleanLinkRemovesEveryListedParameter() {
        let tracking = ["utm_medium=a", "UTM_Campaign=b", "fbclid=c", "gclid=d", "mc_eid=e", "igshid=f", "si=g",
                        "ref_src=h", "spm=i", "_hsenc=j", "_hsmi=k"]
        XCTAssertEqual(apply(.cleanLink, "https://a.example/x?" + tracking.joined(separator: "&") + "#top"),
                       "https://a.example/x#top", "no query left, the fragment stays")
    }

    func testCleanLinkKeepsLookalikeParameters() {
        XCTAssertNil(apply(.cleanLink, "https://a.example/?sid=1&ref=2&spmx=3&utm=4&hs=5"))
    }

    func testCleanLinkCleansEveryLinkInText() {
        XCTAssertEqual(apply(.cleanLink, "Mira https://a.example/?si=1 y https://b.example/?q=café&gclid=2.\r\nChao"),
                       "Mira https://a.example/ y https://b.example/?q=café.\r\nChao")
    }

    func testCleanLinkDoesNotApplyWithoutTracking() {
        XCTAssertNil(apply(.cleanLink, "https://a.example/?q=1#utm_source=x"), "a fragment is not a parameter")
        XCTAssertNil(apply(.cleanLink, "no links here?utm_source=x"))
    }

    // MARK: JSON

    private let compact = #"{"b":1,"a":[1,2.50,{},[]],"s":"x, y: {z} \"q\"","n":12345678901234567890,"e":null}"#
    private let pretty = """
        {
          "b": 1,
          "a": [
            1,
            2.50,
            {},
            []
          ],
          "s": "x, y: {z} \\"q\\"",
          "n": 12345678901234567890,
          "e": null
        }
        """

    func testPrettyJSONKeepsKeyOrderNumbersAndStrings() {
        XCTAssertEqual(apply(.prettyJSON, compact), pretty)
    }

    func testCompactJSON() {
        XCTAssertEqual(apply(.compactJSON, pretty), compact)
        XCTAssertEqual(apply(.compactJSON, "[ 1 ,\r\n 2 ]\r\n"), "[1,2]")
    }

    func testJSONDoesNotApplyWhenAlreadyInThatForm() {
        XCTAssertNil(apply(.compactJSON, compact))
        XCTAssertNil(apply(.prettyJSON, pretty))
    }

    func testInvalidJSONReturnsNil() {
        for text in [#"{"a":}"#, "{a:1}", "[1,2", #""just a string""#, "42", "not json", #"{"a":1} trailing"#] {
            XCTAssertNil(apply(.prettyJSON, text), text)
            XCTAssertNil(apply(.compactJSON, text), text)
        }
    }

    func testJSONWithEmojiAndUnicode() {
        XCTAssertEqual(apply(.compactJSON, "{ \"emoji\" : \"👍🏽 ñ\" }"), #"{"emoji":"👍🏽 ñ"}"#)
    }

    func testGiantJSONRoundTrips() throws {
        let items = (0..<20_000).map { #"{"id":\#($0),"name":"item \#($0)","tags":["a","b"]}"# }
        let big = "[" + items.joined(separator: ",") + "]"
        let expanded = try XCTUnwrap(apply(.prettyJSON, big))
        XCTAssertEqual(apply(.compactJSON, expanded), big)
    }

    func testDeeplyNestedJSONDoesNotCrash() {
        // Accepted or refused by the parser's depth limit, never a crash.
        let deep = String(repeating: "[", count: 2_000) + String(repeating: "]", count: 2_000)
        if let compacted = apply(.compactJSON, String(repeating: "[ ", count: 2_000) + String(repeating: "] ", count: 2_000)) {
            XCTAssertEqual(compacted, deep)
        }
        _ = apply(.prettyJSON, deep)
    }

    // MARK: Applicability

    func testApplicableToPlainText() {
        XCTAssertEqual(TextTransform.applicable(to: "hello there", type: .plainText), [.upper, .title])
    }

    func testPlainAndMarkdownOnlyForFormattedText() {
        XCTAssertEqual(TextTransform.applicable(to: "Hello", type: .richText), [.plain, .markdown, .upper, .lower])
        XCTAssertEqual(TextTransform.applicable(to: "Hello", type: .html), [.plain, .markdown, .upper, .lower])
        XCTAssertFalse(TextTransform.applicable(to: "Hello", type: .plainText).contains(.markdown))
        XCTAssertFalse(TextTransform.applicable(to: "https://a.example", type: .url).contains(.markdown))
    }

    // MARK: Markdown and formatted text

    private let notes = "# Notes\n\n- **milk**\n- eggs"

    /// Offered for plain text that reads as Markdown. A formatted clip already has its formatting.
    func testFormattedTextOnlyForMarkdownPlainText() {
        XCTAssertTrue(TextTransform.applicable(to: notes, type: .plainText).contains(.richText))
        XCTAssertFalse(TextTransform.applicable(to: "Use a * for wildcards", type: .plainText).contains(.richText))
        XCTAssertFalse(TextTransform.applicable(to: notes, type: .richText).contains(.richText))
        XCTAssertFalse(TextTransform.applicable(to: notes, type: .html).contains(.richText))
        XCTAssertFalse(TextTransform.applicable(to: notes, type: .url).contains(.richText))
        // Code wins, as on the cards: a script with `#` comments is not offered as formatted text.
        let script = "# Build\n# Run\nmake all;\nmake test;\nmake install;"
        XCTAssertTrue(MarkdownDetector.isMarkdown(script) && CodeDetector.isCode(script))
        XCTAssertFalse(TextTransform.applicable(to: script, type: .plainText).contains(.richText))
    }

    /// Markdown is made from the clip's data at pick time, not from its text.
    func testMarkdownFromHTMLData() throws {
        let result = try XCTUnwrap(TextTransform.markdown.result(text: "Hi there", type: .html, data: Data("<b>Hi</b> there".utf8)))
        XCTAssertEqual(result.text, "**Hi** there")
        XCTAssertNil(result.rtf)
    }

    func testMarkdownFromRTFData() throws {
        let string = NSMutableAttributedString(string: "Hi", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 12)!])
        string.append(NSAttributedString(string: " there", attributes: [.font: NSFont(name: "Helvetica", size: 12)!]))
        let rtf = try string.data(from: NSRange(location: 0, length: string.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        XCTAssertEqual(TextTransform.markdown.result(text: "Hi there", type: .richText, data: rtf)?.text, "**Hi** there")
        XCTAssertNil(TextTransform.markdown.result(text: "Hi there", type: .richText, data: Data("not rtf".utf8)))
        XCTAssertNil(TextTransform.markdown.result(text: "Hi there", type: .plainText, data: Data("Hi there".utf8)))
    }

    /// "Copy as → Markdown" on both platforms reads the clip's data in a context of its own, off the main thread: a clip
    /// gone meanwhile gives no data, and so no Markdown.
    func testMarkdownDataIsReadInAContextOfItsOwn() throws {
        let schema = Schema(StoreSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let html = Data("<b>Hi</b> there".utf8)
        let clip = ClipboardItem(contentType: .html, rawData: html, textContent: "Hi there", contentHash: "h")
        context.insert(clip)
        try context.save()
        XCTAssertEqual(ClipboardItem.rawData(of: clip.id, in: container), html)
        XCTAssertEqual(ClipboardItem.rawData(of: UUID(), in: container), Data())
        XCTAssertNil(TextTransform.markdown.result(text: "Hi there", type: .richText,
                                                   data: ClipboardItem.rawData(of: UUID(), in: container)))
    }

    /// RTF for apps that take formatting, and the formatted text without its Markdown for the rest.
    func testFormattedTextGivesRTFAndPlainText() throws {
        let result = try XCTUnwrap(TextTransform.richText.result(text: notes, type: .plainText, data: Data()))
        XCTAssertEqual(result.text, "Notes\n\n• milk\n• eggs")
        let rtf = try XCTUnwrap(result.rtf)
        let string = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                            documentAttributes: nil)
        XCTAssertEqual(string.string.trimmingCharacters(in: .newlines), result.text)
        let milk = (string.string as NSString).range(of: "milk").location
        let font = try XCTUnwrap(string.attribute(.font, at: milk, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    /// The other transforms work on the text as before.
    func testResultOfATextTransform() {
        XCTAssertEqual(TextTransform.upper.result(text: "hi", type: .plainText, data: Data())?.text, "HI")
        XCTAssertNil(TextTransform.upper.result(text: "HI", type: .plainText, data: Data()))
        XCTAssertNil(TextTransform.upper.result(text: "hi", type: .plainText, data: Data())?.rtf)
    }

    func testMarkdownTransformsNeverApplyToTextAlone() {
        XCTAssertNil(apply(.markdown, notes))
        XCTAssertNil(apply(.richText, notes))
    }

    func testCleanLinkForLinksAndTextWithALink() {
        XCTAssertTrue(TextTransform.applicable(to: "https://a.example/?fbclid=1", type: .url).contains(.cleanLink))
        XCTAssertTrue(TextTransform.applicable(to: "see https://a.example/?fbclid=1", type: .plainText).contains(.cleanLink))
        XCTAssertFalse(TextTransform.applicable(to: "https://a.example/?q=1", type: .url).contains(.cleanLink))
    }

    func testJSONOnlyForValidJSON() {
        let compacted = TextTransform.applicable(to: compact, type: .plainText)
        XCTAssertTrue(compacted.contains(.prettyJSON))
        XCTAssertFalse(compacted.contains(.compactJSON), "already compact")
        XCTAssertTrue(Set(TextTransform.applicable(to: "[1, 2]", type: .plainText)).isSuperset(of: [.prettyJSON, .compactJSON]))
        XCTAssertTrue(Set(TextTransform.applicable(to: "{nope}", type: .plainText)).isDisjoint(with: [.prettyJSON, .compactJSON]))
    }

    // MARK: Menu probe

    /// A long clip's menu comes from its first 4 KB, so a 200 KB clip costs no more than a short one.
    func testMenuOfALongTextComesFromItsFirst4KB() {
        // 4 KB of lowercase text with untracked links, then 200 KB of tracked links.
        let text = String(repeating: "see https://a.example/?q=1 ", count: 160)
            + String(repeating: "Visit https://b.example/?utm_source=x ", count: 5_300)
        XCTAssertGreaterThan(text.utf8.count, 200_000)
        var menu: [TextTransform] = []
        let elapsed = ContinuousClock().measure { menu = TextTransform.applicable(to: text, type: .plainText) }
        XCTAssertLessThan(elapsed, .milliseconds(100), "\(elapsed)")
        XCTAssertEqual(menu, [.upper, .title], "lowercase, Trim and Clean link would only change the text after 4 KB")
    }

    /// The 4 KB cut lands right after a space here: that space is mid-line in the clip, nothing to trim.
    func testCutAfterASpaceDoesNotOfferTrim() {
        let text = String(repeating: "abc ", count: 2_000) + "abc"
        XCTAssertEqual(TextTransform.applicable(to: text, type: .plainText), [.upper, .title])
    }

    /// Only the whole text can be parsed: a long clip that opens like an object or an array is offered both, and a
    /// pick the rest of the text doesn't support gives nil, so nothing is pasted.
    func testJSONMenuOfALongText() {
        let valid = "[" + (0..<500).map { #"{"id": \#($0)}"# }.joined(separator: ", ") + "]"
        XCTAssertGreaterThan(valid.utf8.count, TextTransform.menuProbeLimit)
        let invalid = String(valid.dropLast())
        for text in [valid, " \n" + invalid] {
            XCTAssertTrue(Set(TextTransform.applicable(to: text, type: .plainText)).isSuperset(of: [.prettyJSON, .compactJSON]))
        }
        XCTAssertNotNil(apply(.prettyJSON, valid))
        XCTAssertNil(apply(.prettyJSON, invalid))
        XCTAssertNil(apply(.compactJSON, invalid))
        XCTAssertTrue(Set(TextTransform.applicable(to: "x" + valid, type: .plainText)).isDisjoint(with: [.prettyJSON, .compactJSON]))
    }

    func testNothingAppliesToImagesFilesOrColors() {
        for type in [ContentType.image, .files, .fileURL, .color, .unknown] {
            XCTAssertEqual(TextTransform.applicable(to: "Some text", type: type), [], "\(type)")
        }
    }

    // MARK: Labels

    /// The test bundle carries the iPhone's catalog; its `es.lproj` picks Spanish whatever this Mac's language is.
    func testLabels() throws {
        XCTAssertEqual(TextTransform.allCases.map { $0.label() },
                       ["Plain text", "Markdown", "Formatted text", "UPPERCASE", "lowercase", "Title Case",
                        "Trim whitespace", "Clean link", "Pretty JSON", "Compact JSON"])
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "es", ofType: "lproj"))
        let es = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(TextTransform.allCases.map { $0.label(bundle: es) },
                       ["Texto sin formato", "Markdown", "Texto con formato", "MAYÚSCULAS", "minúsculas", "Tipo Título",
                        "Quitar espacios sobrantes", "Limpiar link", "JSON legible", "JSON compacto"])
    }
}
