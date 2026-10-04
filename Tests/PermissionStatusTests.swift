import XCTest

/// One test per state `PermissionStatus.resolve` can return for a Settings permissions row.
final class PermissionStatusTests: XCTestCase {
    // MARK: - Mac rows: granted / missing / notNeeded

    func testGrantedWhileTheFeatureIsOn() {
        XCTAssertEqual(PermissionStatus.resolve(granted: true, featureOn: true), .granted)
    }

    func testMissingWhileTheFeatureIsOn() {
        XCTAssertEqual(PermissionStatus.resolve(granted: false, featureOn: true), .missing)
    }

    func testNotNeededWhileTheFeatureIsOffWithoutAccess() {
        XCTAssertEqual(PermissionStatus.resolve(granted: false, featureOn: false), .notNeeded,
                       "Accessibility with Paste directly off is informational, never a warning")
    }

    func testNotNeededWhileTheFeatureIsOffWithAccess() {
        XCTAssertEqual(PermissionStatus.resolve(granted: true, featureOn: false), .notNeeded)
    }

    // MARK: - iOS: Copyd keyboard added / not added

    func testKeyboardAdded() {
        let keyboards = ["en_US@sw=QWERTY;hw=Automatic", "emoji@sw=Emoji", "com.robbyfuu.copyd.keyboard"]
        XCTAssertEqual(PermissionStatus.resolve(enabledKeyboards: keyboards), .granted)
    }

    func testKeyboardNotAdded() {
        XCTAssertEqual(PermissionStatus.resolve(enabledKeyboards: ["en_US@sw=QWERTY;hw=Automatic", "emoji@sw=Emoji"]),
                       .missing)
    }

    func testKeyboardNotAddedWhenTheListCannotBeRead() {
        XCTAssertEqual(PermissionStatus.resolve(enabledKeyboards: nil), .missing)
    }

    // MARK: - iOS: Full Access confirmed / unconfirmed

    func testFullAccessConfirmedOnceTheKeyboardRecordedIt() {
        XCTAssertEqual(PermissionStatus.resolve(fullAccessSeenAt: Date(timeIntervalSince1970: 1_790_000_000)), .granted)
    }

    func testFullAccessUnconfirmedUntilTheKeyboardOpensWithIt() {
        XCTAssertEqual(PermissionStatus.resolve(fullAccessSeenAt: nil), .unconfirmed,
                       "no record may only mean the keyboard hasn't opened yet: neutral, not missing")
    }
}
