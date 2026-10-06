import CoreSpotlight
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
        XCTAssertEqual(try route("copyd://history"), .history, "the arrival notice opens History")
        XCTAssertEqual(try route("copyd://Search"), .search, "the host is case-insensitive")
        XCTAssertEqual(try route("COPYD://search"), .search, "the scheme is case-insensitive")
    }

    func testParsesEveryShortcutType() {
        XCTAssertEqual(QuickRoute(shortcutType: "com.robbyfuu.copyd.save-clipboard"), .saveClipboard)
        XCTAssertEqual(QuickRoute(shortcutType: "com.robbyfuu.copyd.search"), .search)
        XCTAssertEqual(QuickRoute(shortcutType: "com.robbyfuu.copyd.pinboards"), .pinboards)
        XCTAssertEqual(QuickRoute(shortcutType: "com.robbyfuu.copyd.keyboard-setup"), .keyboardSetup)
    }

    func testParsesCopyRoute() throws {
        let id = UUID()
        XCTAssertEqual(try route("copyd://copy/\(id.uuidString)"), .copy(id))
        XCTAssertEqual(try route("copyd://COPY/\(id.uuidString.lowercased())"), .copy(id), "host and UUID case do not matter")
        XCTAssertEqual(QuickRoute(url: QuickRoute.copyURL(id)), .copy(id), "the widget's link round-trips")
    }

    func testRejectsCopyWithBadUUID() throws {
        XCTAssertNil(try route("copyd://copy/not-a-uuid"))
        XCTAssertNil(try route("copyd://copy"))
        XCTAssertNil(try route("copyd://copy/"))
        XCTAssertNil(try route("copyd://copy/\(UUID().uuidString)/extra"))
        XCTAssertNil(QuickRoute(shortcutType: "com.robbyfuu.copyd.copy"), "a quick action cannot carry a clip")
    }

    /// A web page must never make Copyd read the pasteboard, so a link may open every route except save.
    func testSaveClipboardURLIsRejectedByAppPolicy() throws {
        XCTAssertFalse(QuickRoute.allowsURL(.saveClipboard))
        XCTAssertTrue(QuickRoute.allowsURL(.search), "the search control and links may focus search")
        XCTAssertTrue(QuickRoute.allowsURL(.history))
        XCTAssertTrue(QuickRoute.allowsURL(.copy(UUID())), "the widget's copy links still work")
    }

    func testRejectsOtherSchemeAndUnknownRoute() throws {
        XCTAssertNil(try route("https://search"))
        XCTAssertNil(try route("copyd://nope"))
        XCTAssertNil(QuickRoute(shortcutType: "com.robbyfuu.copyd.nope"))
        XCTAssertNil(QuickRoute(shortcutType: "search"))
    }

    /// A tapped Spotlight result copies its clip. The constants are CoreSpotlight's, spelled out so `QuickRoute`
    /// never links CoreSpotlight into the extensions.
    func testSpotlightActivityRoutesToCopy() {
        XCTAssertEqual(QuickRoute.spotlightActivityType, CSSearchableItemActionType)
        XCTAssertEqual(QuickRoute.spotlightIDKey, CSSearchableItemActivityIdentifier)
        let id = UUID()
        XCTAssertEqual(QuickRoute(activityType: CSSearchableItemActionType,
                                  userInfo: [CSSearchableItemActivityIdentifier: id.uuidString]), .copy(id))
        XCTAssertNil(QuickRoute(activityType: "com.robbyfuu.copyd.other", userInfo: [CSSearchableItemActivityIdentifier: id.uuidString]),
                     "another activity")
        XCTAssertNil(QuickRoute(activityType: CSSearchableItemActionType, userInfo: nil))
        XCTAssertNil(QuickRoute(activityType: CSSearchableItemActionType, userInfo: [CSSearchableItemActivityIdentifier: "nope"]))
        XCTAssertNil(QuickRoute(activityType: CSSearchableItemActionType, userInfo: [CSSearchableItemActivityIdentifier: 42]))
    }
}
