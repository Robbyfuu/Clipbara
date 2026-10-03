import XCTest

final class QuickRouteTests: XCTestCase {
    private func route(_ string: String) throws -> QuickRoute? {
        QuickRoute(url: try XCTUnwrap(URL(string: string)))
    }

    func testParsesEveryURL() throws {
        XCTAssertEqual(try route("copyd://save-clipboard"), .saveClipboard)
        XCTAssertEqual(try route("copyd://search"), .search)
        XCTAssertEqual(try route("copyd://pinboards"), .pinboards)
        XCTAssertEqual(try route("copyd://keyboard-setup"), .keyboardSetup)
        XCTAssertEqual(try route("COPYD://search"), .search, "the scheme is case-insensitive")
    }

    func testParsesEveryShortcutType() {
        XCTAssertEqual(QuickRoute(shortcutType: "com.robbyfuu.copyd.save-clipboard"), .saveClipboard)
        XCTAssertEqual(QuickRoute(shortcutType: "com.robbyfuu.copyd.search"), .search)
        XCTAssertEqual(QuickRoute(shortcutType: "com.robbyfuu.copyd.pinboards"), .pinboards)
        XCTAssertEqual(QuickRoute(shortcutType: "com.robbyfuu.copyd.keyboard-setup"), .keyboardSetup)
    }

    func testRejectsOtherSchemeAndUnknownRoute() throws {
        XCTAssertNil(try route("https://search"))
        XCTAssertNil(try route("copyd://nope"))
        XCTAssertNil(QuickRoute(shortcutType: "com.robbyfuu.copyd.nope"))
        XCTAssertNil(QuickRoute(shortcutType: "search"))
    }
}
