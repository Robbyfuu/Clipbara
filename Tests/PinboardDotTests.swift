import XCTest

final class PinboardDotTests: XCTestCase {
    func testSameIDSameIndex() {
        let id = UUID()
        XCTAssertEqual(PinboardDot.index(for: id), PinboardDot.index(for: id))
    }

    func testKnownID() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        XCTAssertEqual(PinboardDot.index(for: id), 1)
    }

    func testIndexInRange() {
        for _ in 0..<200 {
            XCTAssertTrue((0..<PinboardDot.paletteCount).contains(PinboardDot.index(for: UUID())))
        }
    }
}
