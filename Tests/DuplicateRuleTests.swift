import XCTest

final class DuplicateRuleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let lo = "00000000-0000-0000-0000-000000000001"
    private let hi = "00000000-0000-0000-0000-000000000002"

    private func clip(id: String, hash: String = "h", dt: TimeInterval = 0,
                      pinned: Bool = false, title: String? = nil) -> ClipSnapshot {
        ClipSnapshot(
            id: UUID(uuidString: id)!, contentType: "plainText", rawData: Data(), textContent: nil,
            userTitle: title, sourceAppName: nil, sourceAppBundleId: nil, contentHash: hash,
            copiedAt: t0.addingTimeInterval(dt), isPinned: pinned)
    }

    func testMergesAt59Seconds() {
        XCTAssertNotNil(DuplicateRule.merge(clip(id: lo), clip(id: hi, dt: 59)))
    }

    func testMergesAtExactly60Seconds() {
        XCTAssertNotNil(DuplicateRule.merge(clip(id: lo), clip(id: hi, dt: 60)))
    }

    func testDoesNotMergeAt61Seconds() {
        XCTAssertNil(DuplicateRule.merge(clip(id: lo), clip(id: hi, dt: 61)))
    }

    func testDifferentHashNeverMerges() {
        XCTAssertNil(DuplicateRule.merge(clip(id: lo, hash: "a"), clip(id: hi, hash: "b")))
    }

    func testSameIDNeverMerges() {
        XCTAssertNil(DuplicateRule.merge(clip(id: lo), clip(id: lo, dt: 1)))
    }

    func testSurvivorIndependentOfOrder() {
        let a = clip(id: lo, pinned: true, title: "a"), b = clip(id: hi, dt: 5, title: "b")
        XCTAssertEqual(DuplicateRule.merge(a, b), DuplicateRule.merge(b, a))
        XCTAssertEqual(DuplicateRule.merge(a, b)?.survivorID, a.id)
        XCTAssertEqual(DuplicateRule.merge(a, b)?.loserID, b.id)
    }

    func testPinIsOR() {
        XCTAssertEqual(DuplicateRule.merge(clip(id: lo), clip(id: hi, pinned: true))?.isPinned, true)
        XCTAssertEqual(DuplicateRule.merge(clip(id: lo, pinned: true), clip(id: hi))?.isPinned, true)
        XCTAssertEqual(DuplicateRule.merge(clip(id: lo), clip(id: hi))?.isPinned, false)
    }

    func testSurvivorTitleWins() {
        XCTAssertEqual(DuplicateRule.merge(clip(id: lo, title: "s"), clip(id: hi, title: "l"))?.userTitle, "s")
    }

    func testLoserTitleFillsNilSurvivorTitle() {
        XCTAssertEqual(DuplicateRule.merge(clip(id: lo), clip(id: hi, title: "l"))?.userTitle, "l")
    }

    func testMergeKeepsLatestCopiedAt() {
        let older = clip(id: lo), newer = clip(id: hi, dt: 30)
        XCTAssertEqual(DuplicateRule.merge(older, newer)?.copiedAt, newer.copiedAt)
        XCTAssertEqual(DuplicateRule.merge(newer, older)?.copiedAt, newer.copiedAt)
    }
}
