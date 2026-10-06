import XCTest

final class AppIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let own = "com.robbyfuu.copyd"
    private let day: TimeInterval = 86_400

    // MARK: Record name

    /// `app-` plus the SHA-256 hex of the bundle id: fixed forever, or every device would upload a second record.
    func testRecordNameIsStableSHA256() {
        XCTAssertEqual(AppIdentity.recordName(for: "com.apple.Safari"),
                       "app-7cd9df4fce2816bcb43439ff7638726c728d3c1a222fb8255447e8be2a8569ca")
        XCTAssertEqual(AppIdentity.recordName(for: "com.tinyspeck.slackmacgap"),
                       "app-6700e8aef65c2837e6321b42f325c1ce6feb1c7e6b6918bbf95907849baa6941")
    }

    /// The local id is the first 16 bytes of the same hash, so every device gives one app the same id.
    func testLocalIDComesFromTheRecordName() {
        let id = AppIdentity.id(for: "com.apple.Safari")
        XCTAssertEqual(id.uuidString, "7CD9DF4F-CE28-16BC-B434-39FF7638726C")
        XCTAssertEqual(SyncRecordMapper.localID(AppIdentity.recordName(for: "com.apple.Safari")), id)
        XCTAssertEqual(AppIdentity(bundleId: "com.apple.Safari", name: "Safari", iconPNG: Data(), colorHex: "#1E90FF").id, id)
    }

    func testLocalIDOfOtherNames() {
        let uuid = UUID()
        XCTAssertEqual(SyncRecordMapper.localID(uuid.uuidString), uuid)
        XCTAssertNil(SyncRecordMapper.localID("app-xyz"))
        XCTAssertNil(SyncRecordMapper.localID("junk"))
    }

    // MARK: Publish rule

    func testPublishesAnAppWithNoIdentity() {
        XCTAssertTrue(AppIdentityPublisher.needsPublish(existing: nil, now: now, bundleId: "com.apple.Safari", ownBundleId: own))
    }

    func testSkipsAFreshIdentity() {
        XCTAssertFalse(AppIdentityPublisher.needsPublish(existing: now.addingTimeInterval(-29 * day), now: now,
                                                         bundleId: "com.apple.Safari", ownBundleId: own))
        XCTAssertFalse(AppIdentityPublisher.needsPublish(existing: now.addingTimeInterval(-30 * day), now: now,
                                                         bundleId: "com.apple.Safari", ownBundleId: own),
                       "exactly 30 days is not older than 30 days")
    }

    func testRefreshesAfterThirtyDays() {
        XCTAssertTrue(AppIdentityPublisher.needsPublish(existing: now.addingTimeInterval(-31 * day), now: now,
                                                        bundleId: "com.apple.Safari", ownBundleId: own))
    }

    func testNeverPublishesCopydItself() {
        XCTAssertFalse(AppIdentityPublisher.needsPublish(existing: nil, now: now, bundleId: own, ownBundleId: own))
        XCTAssertFalse(AppIdentityPublisher.needsPublish(existing: now.addingTimeInterval(-90 * day), now: now,
                                                         bundleId: own, ownBundleId: own))
    }
}
