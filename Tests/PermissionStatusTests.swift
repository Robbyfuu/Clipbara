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

    // MARK: - iOS: Copyd keyboard added / not added / unknown

    func testKeyboardAdded() {
        let keyboards = ["en_US@sw=QWERTY;hw=Automatic", "emoji@sw=Emoji", "com.robbyfuu.copyd.keyboard"]
        XCTAssertEqual(PermissionStatus.resolve(enabledKeyboards: keyboards, fullAccessSeenAt: nil), .granted)
    }

    func testKeyboardNotAdded() {
        XCTAssertEqual(PermissionStatus.resolve(enabledKeyboards: ["en_US@sw=QWERTY;hw=Automatic", "emoji@sw=Emoji"],
                                                fullAccessSeenAt: nil), .missing)
    }

    func testKeyboardMatchIsExact() {
        let similar = ["com.robbyfuu.copyd.keyboard2", "com.robbyfuu.copyd.keyboard.old", "com.robbyfuu.copyd"]
        XCTAssertEqual(PermissionStatus.resolve(enabledKeyboards: similar, fullAccessSeenAt: nil), .missing)
    }

    func testKeyboardUnknownWhenTheListIsMissing() {
        XCTAssertEqual(PermissionStatus.resolve(enabledKeyboards: nil, fullAccessSeenAt: nil), .unconfirmed,
                       "no AppleKeyboards key at all: neutral, not a warning")
    }

    func testKeyboardAddedOnceItRecordedFullAccess() {
        let seen = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(PermissionStatus.resolve(enabledKeyboards: ["emoji@sw=Emoji"], fullAccessSeenAt: seen), .granted,
                       "the keyboard ran, so it is added whatever AppleKeyboards says")
        XCTAssertEqual(PermissionStatus.resolve(enabledKeyboards: nil, fullAccessSeenAt: seen), .granted)
    }

    // MARK: - iOS: Full Access confirmed in the last 7 days

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    func testFullAccessGrantedJustUnderSevenDays() {
        let seen = now.addingTimeInterval(-(6 * 86_400 + 23 * 3600))
        XCTAssertEqual(PermissionStatus.resolve(fullAccessSeenAt: seen, now: now), .granted)
    }

    func testFullAccessUnconfirmedAtSevenDays() {
        let seen = now.addingTimeInterval(-7 * 86_400)
        XCTAssertEqual(PermissionStatus.resolve(fullAccessSeenAt: seen, now: now), .unconfirmed,
                       "an old record may predate Full Access being turned off")
    }

    func testFullAccessUnconfirmedUntilTheKeyboardOpensWithIt() {
        XCTAssertEqual(PermissionStatus.resolve(fullAccessSeenAt: nil, now: now), .unconfirmed,
                       "no record may only mean the keyboard hasn't opened yet: neutral, not missing")
    }

    // MARK: - Keyboard: rewrite the Full Access date at most once a day

    func testKeyboardRecordsFullAccessWhenThereIsNoDate() {
        XCTAssertTrue(PermissionStatus.shouldRecordFullAccess(seenAt: nil, now: now))
    }

    func testKeyboardSkipsTheWriteWithinADay() {
        XCTAssertFalse(PermissionStatus.shouldRecordFullAccess(seenAt: now.addingTimeInterval(-23 * 3600), now: now))
        XCTAssertFalse(PermissionStatus.shouldRecordFullAccess(seenAt: now.addingTimeInterval(-86_400), now: now))
    }

    func testKeyboardRecordsFullAccessOnceTheDateIsOverADayOld() {
        XCTAssertTrue(PermissionStatus.shouldRecordFullAccess(seenAt: now.addingTimeInterval(-86_401), now: now))
    }
}
