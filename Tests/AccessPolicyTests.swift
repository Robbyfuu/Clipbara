import XCTest

final class AccessPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Double) -> TimeInterval { n * 24 * 60 * 60 }

    private func state(
        grandfathered: Bool? = false,
        lifetime: Bool? = false,
        trialStartedDaysAgo: Double? = nil
    ) -> AccessState {
        AccessPolicy.state(
            isGrandfathered: grandfathered,
            hasLifetime: lifetime,
            trialStart: trialStartedDaysAgo.map { now.addingTimeInterval(-days($0)) },
            now: now
        )
    }

    // MARK: - Unlocked

    func testLifetimeUnlocksEvenAfterTheTrialEnded() {
        XCTAssertEqual(state(lifetime: true, trialStartedDaysAgo: 30), .unlocked(.lifetime))
    }

    func testLifetimeWinsWhenGrandfatheringIsUnknown() {
        XCTAssertEqual(state(grandfathered: nil, lifetime: true), .unlocked(.lifetime))
    }

    func testGrandfatheredUsersNeverSeeTheTrial() {
        XCTAssertEqual(state(grandfathered: true), .unlocked(.grandfathered))
        XCTAssertEqual(state(grandfathered: true, trialStartedDaysAgo: 30), .unlocked(.grandfathered))
    }

    func testGrandfatheredStillUnlocksWhenPurchasesAreUnknown() {
        XCTAssertEqual(state(grandfathered: true, lifetime: nil), .unlocked(.grandfathered))
    }

    // MARK: - Fail open

    func testUnknownAppTransactionFailsOpen() {
        XCTAssertEqual(state(grandfathered: nil), .unlocked(.unverified))
        XCTAssertEqual(state(grandfathered: nil, trialStartedDaysAgo: 30), .unlocked(.unverified))
    }

    func testUnknownPurchaseHistoryFailsOpen() {
        XCTAssertEqual(state(lifetime: nil), .unlocked(.unverified))
        XCTAssertEqual(state(lifetime: nil, trialStartedDaysAgo: 30), .unlocked(.unverified))
    }

    // MARK: - Trial

    func testNoTrialYet() {
        XCTAssertEqual(state(), .trialNotStarted)
        XCTAssertFalse(state().allowsHistoryAccess)
    }

    func testTrialJustStarted() {
        XCTAssertEqual(state(trialStartedDaysAgo: 0), .trialActive(daysLeft: 7))
        XCTAssertTrue(state(trialStartedDaysAgo: 0).allowsHistoryAccess)
    }

    func testDaysLeftRoundsUp() {
        XCTAssertEqual(state(trialStartedDaysAgo: 0.5), .trialActive(daysLeft: 7))
        XCTAssertEqual(state(trialStartedDaysAgo: 1), .trialActive(daysLeft: 6))
        XCTAssertEqual(state(trialStartedDaysAgo: 6), .trialActive(daysLeft: 1))
        XCTAssertEqual(state(trialStartedDaysAgo: 6.99), .trialActive(daysLeft: 1))
    }

    func testTrialLastsExactlySevenTimesTwentyFourHours() {
        let start = now.addingTimeInterval(-days(7))
        XCTAssertEqual(
            AccessPolicy.state(isGrandfathered: false, hasLifetime: false, trialStart: start, now: now.addingTimeInterval(-1)),
            .trialActive(daysLeft: 1)
        )
        XCTAssertEqual(
            AccessPolicy.state(isGrandfathered: false, hasLifetime: false, trialStart: start, now: now),
            .trialExpired
        )
    }

    func testTrialExpired() {
        XCTAssertEqual(state(trialStartedDaysAgo: 8), .trialExpired)
        XCTAssertFalse(state(trialStartedDaysAgo: 8).allowsHistoryAccess)
    }

    func testTrialStartAheadOfTheClockIsCapped() {
        XCTAssertEqual(state(trialStartedDaysAgo: -3), .trialActive(daysLeft: 7))
    }

    func testTrialEndDate() {
        XCTAssertEqual(AccessPolicy.trialEnd(from: now), now.addingTimeInterval(604_800))
    }

    // MARK: - Grandfathering by original version

    func testVersionsBeforeTheTrialModelAreGrandfathered() {
        for version in ["1.0", "1.3", "1.3.0", "1.3.3", "1.3.10", "0.9"] {
            XCTAssertEqual(AccessPolicy.isGrandfathered(originalAppVersion: version), true, version)
        }
    }

    func testTrialModelVersionAndLaterAreNot() {
        for version in ["1.4", "1.4.0", "1.4.1", "1.10", "2", "2.0.0"] {
            XCTAssertEqual(AccessPolicy.isGrandfathered(originalAppVersion: version), false, version)
        }
    }

    func testUnparseableVersionIsUnknown() {
        for version in ["", " ", "abc", "1..4", "1.4b", "-1.0", "+1.3", "1."] {
            XCTAssertNil(AccessPolicy.isGrandfathered(originalAppVersion: version), version)
        }
    }

    func testBareBuildNumberFallback() {
        for build in ["22", "23", "26", "28", "29", "30"] {
            XCTAssertEqual(AccessPolicy.isGrandfathered(originalAppVersion: build), true, build)
        }
        for build in ["31", "32", "40"] {
            XCTAssertEqual(AccessPolicy.isGrandfathered(originalAppVersion: build), false, build)
        }
    }

    func testOriginalPlatform() {
        // Bought on the Mac before 1.4: kept, with or without the platform.
        XCTAssertEqual(AccessPolicy.isGrandfathered(originalAppVersion: "1.3.2", originalPlatform: .mac), true)
        XCTAssertEqual(AccessPolicy.isGrandfathered(originalAppVersion: "1.3.2", originalPlatform: .unknown), true)
        // First got it on iPhone: never the old paid Mac app, even if the version reads as older.
        for version in ["1", "1.0", "1.3.2", "29"] {
            XCTAssertEqual(AccessPolicy.isGrandfathered(originalAppVersion: version, originalPlatform: .other), false, version)
        }
        XCTAssertEqual(AccessPolicy.isGrandfathered(originalAppVersion: "1.4", originalPlatform: .mac), false)
        XCTAssertNil(AccessPolicy.isGrandfathered(originalAppVersion: "abc", originalPlatform: .mac))
    }

    func testVersionComponents() {
        XCTAssertEqual(AccessPolicy.versionComponents("1.3.3"), [1, 3, 3])
        XCTAssertEqual(AccessPolicy.versionComponents(" 1.4 "), [1, 4])
        XCTAssertNil(AccessPolicy.versionComponents("1.٣"))
    }
}
