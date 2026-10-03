import XCTest

final class ClipAgeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func age(_ seconds: TimeInterval) -> String {
        ClipAge.text(from: now.addingTimeInterval(-seconds), now: now)
    }

    func testNow() {
        XCTAssertEqual(age(0), "now")
        XCTAssertEqual(age(59), "now")
    }

    func testFuture() { XCTAssertEqual(age(-120), "now") }

    func testMinutes() {
        XCTAssertEqual(age(59), "now")
        XCTAssertEqual(age(60), "1 min")
        XCTAssertEqual(age(3599), "59 min")
    }

    func testHours() {
        XCTAssertEqual(age(3600), "1 h")
        XCTAssertEqual(age(86_399), "23 h")
    }

    func testDays() {
        XCTAssertEqual(age(86_400), "1 d")
        XCTAssertEqual(age(3 * 86_400), "3 d")
    }
}
