import XCTest

final class LinkPartsTests: XCTestCase {
    func testDropsWwwAndKeepsPathAndQuery() throws {
        let parts = try XCTUnwrap(LinkParts.split("https://www.airbnb.cl/rooms/123?adults=3"))
        XCTAssertEqual(parts.host, "airbnb.cl")
        XCTAssertEqual(parts.rest, "/rooms/123?adults=3")
    }

    func testLoneTrailingSlashBecomesEmpty() throws {
        let parts = try XCTUnwrap(LinkParts.split("https://developer.apple.com/"))
        XCTAssertEqual(parts.host, "developer.apple.com")
        XCTAssertEqual(parts.rest, "")
    }

    func testNoHostIsNil() {
        XCTAssertNil(LinkParts.split("not a url"))
    }

    func testBareLinkAcceptsHTTPS() throws {
        let parts = try XCTUnwrap(LinkParts.bareLink("  https://www.airbnb.cl/rooms/1289?adults=3\n"))
        XCTAssertEqual(parts.host, "airbnb.cl")
        XCTAssertEqual(parts.rest, "/rooms/1289?adults=3")
    }

    func testBareLinkRejectsText() {
        XCTAssertNil(LinkParts.bareLink("Si buscas el lugar perfecto https://airbnb.cl"))
    }

    func testBareLinkRejectsNonHTTP() {
        XCTAssertNil(LinkParts.bareLink("mailto:a@b.cl"))
        XCTAssertNil(LinkParts.bareLink("464501"))
    }
}
