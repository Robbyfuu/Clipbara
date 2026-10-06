import XCTest

final class AppIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let own = "com.robbyfuu.copyd"
    private let day: TimeInterval = 86_400

    // MARK: Record name

    /// Ruling R6: record names are not encrypted, so they never say which apps the user copies from. Each new identity
    /// gets a random id, and its record is named by it, like a clip's.
    func testEachNewIdentityHasARandomID() {
        let a = AppIdentity(bundleId: "com.apple.Safari", name: "Safari", iconPNG: Data(), colorHex: "#1E90FF")
        let b = AppIdentity(bundleId: "com.apple.Safari", name: "Safari", iconPNG: Data(), colorHex: "#1E90FF")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(SyncRecordMapper.localID(SyncRecordMapper.recordID(for: a.id).recordName), a.id)
    }

    func testLocalIDOfOtherNames() {
        let uuid = UUID()
        XCTAssertEqual(SyncRecordMapper.localID(uuid.uuidString), uuid)
        XCTAssertNil(SyncRecordMapper.localID("app-7cd9df4fce2816bcb43439ff7638726c728d3c1a222fb8255447e8be2a8569ca"),
                     "the hashed form is gone")
        XCTAssertNil(SyncRecordMapper.localID("junk"))
    }

    // MARK: Publish rule

    func testPublishesAnAppWithNoIdentity() {
        XCTAssertTrue(AppIdentityPublisher.needsPublish(existing: nil, now: now, bundleId: "com.apple.Safari", ownBundleId: own))
    }

    func testSkipsAFreshIdentity() {
        XCTAssertFalse(AppIdentityPublisher.needsPublish(existing: now.addingTimeInterval(-6 * day), now: now,
                                                         bundleId: "com.apple.Safari", ownBundleId: own))
        XCTAssertFalse(AppIdentityPublisher.needsPublish(existing: now.addingTimeInterval(-7 * day), now: now,
                                                         bundleId: "com.apple.Safari", ownBundleId: own),
                       "exactly 7 days is not older than 7 days")
    }

    /// A device updated after the Mac published gets the icons within a week.
    func testRefreshesAfterSevenDays() {
        XCTAssertTrue(AppIdentityPublisher.needsPublish(existing: now.addingTimeInterval(-8 * day), now: now,
                                                        bundleId: "com.apple.Safari", ownBundleId: own))
    }

    /// A secret stays on this Mac, so the app it came from is not announced either.
    func testNeverPublishesFromASecret() {
        XCTAssertFalse(AppIdentityPublisher.needsPublish(existing: nil, now: now, bundleId: "com.apple.Safari",
                                                         ownBundleId: own, isSensitive: true))
    }

    // MARK: Conflicts

    /// A Mac's upload met another Mac's copy on the server: the server copy wins unless the local one is newer.
    func testServerWinsWhenNewerOrEqual() {
        XCTAssertTrue(AppIdentityPublisher.serverWins(server: now.addingTimeInterval(10), local: now))
        XCTAssertTrue(AppIdentityPublisher.serverWins(server: now, local: now), "a tie keeps what the server holds")
        XCTAssertFalse(AppIdentityPublisher.serverWins(server: now, local: now.addingTimeInterval(10)))
    }

    func testOnlyTheMacPublishes() {
        XCTAssertTrue(AppIdentityPublisher.publishesHere, "this test target is macOS")
    }

    func testNeverPublishesCopydItself() {
        XCTAssertFalse(AppIdentityPublisher.needsPublish(existing: nil, now: now, bundleId: own, ownBundleId: own))
        XCTAssertFalse(AppIdentityPublisher.needsPublish(existing: now.addingTimeInterval(-90 * day), now: now,
                                                         bundleId: own, ownBundleId: own))
    }
}
