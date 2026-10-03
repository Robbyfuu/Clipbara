import XCTest

final class RelativeSyncTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNever() { XCTAssertEqual(RelativeSyncTime.text(from: nil, now: now), "Never synced") }

    func testNowUnder60s() {
        XCTAssertEqual(RelativeSyncTime.text(from: now.addingTimeInterval(-59), now: now), "Updated now")
        XCTAssertEqual(RelativeSyncTime.text(from: now.addingTimeInterval(100), now: now), "Updated now")
    }

    func testMinutes() {
        XCTAssertEqual(RelativeSyncTime.text(from: now.addingTimeInterval(-60), now: now), "Updated 1 min ago")
        XCTAssertEqual(RelativeSyncTime.text(from: now.addingTimeInterval(-3599), now: now), "Updated 59 min ago")
    }

    func testHours() {
        XCTAssertEqual(RelativeSyncTime.text(from: now.addingTimeInterval(-3600), now: now), "Updated 1 h ago")
        XCTAssertEqual(RelativeSyncTime.text(from: now.addingTimeInterval(-86_399), now: now), "Updated 23 h ago")
    }

    func testDays() {
        XCTAssertEqual(RelativeSyncTime.text(from: now.addingTimeInterval(-86_400), now: now), "Updated 1 d ago")
        XCTAssertEqual(RelativeSyncTime.text(from: now.addingTimeInterval(-3 * 86_400), now: now), "Updated 3 d ago")
    }
}
