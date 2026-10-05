import XCTest

final class ArrivalNoticeTests: XCTestCase {
    func testSingleClipTitleAndTruncation() {
        let notice = ArrivalNotice.content(previews: [String(repeating: "a", count: 100)])
        XCTAssertEqual(notice.title, "New clip from another device", "an iPad or a second iPhone sends clips too")
        XCTAssertEqual(notice.body, String(repeating: "a", count: 80) + "\u{2026}")
        let exact = String(repeating: "é", count: 80)
        XCTAssertEqual(ArrivalNotice.content(previews: [exact]).body, exact, "80 characters fit whole")
    }

    func testPluralTitle() {
        let notice = ArrivalNotice.content(previews: ["newest", "older", "oldest"])
        XCTAssertEqual(notice.title, "3 new clips")
        XCTAssertEqual(notice.body, "newest", "the body shows the newest clip")
    }

    /// The test bundle carries the iPhone's catalog. Its `es.lproj` picks Spanish whatever this Mac's language is;
    /// a `Locale` argument would not, since lookups follow the preferred languages.
    func testSpanishTitles() throws {
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "es", ofType: "lproj"))
        let es = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(ArrivalNotice.content(previews: ["hola"], bundle: es).title, "Nuevo clip de otro equipo")
        XCTAssertEqual(ArrivalNotice.content(previews: ["a", "b", "c"], bundle: es).title, "3 clips nuevos")
    }

    func testEmptyPreviewUsesTypeName() {
        XCTAssertEqual(ArrivalNotice.preview(type: .image, text: nil), "Image")
        XCTAssertEqual(ArrivalNotice.preview(type: .plainText, text: " \n\t "), "Text")
        XCTAssertEqual(ArrivalNotice.preview(type: .plainText, text: "  line one\n\nline   two "), "line one line two",
                       "one line, runs of whitespace collapsed")
    }
}
