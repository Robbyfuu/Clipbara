import XCTest

final class PanelGeometryTests: XCTestCase {
    func testFullWidthBottomAligned() {
        let f = PanelGeometry.frame(visibleFrame: NSRect(x: 0, y: 25, width: 1512, height: 920), height: 300)
        XCTAssertEqual(f, NSRect(x: 0, y: 25, width: 1512, height: 300))
    }

    func testSecondaryScreenWithNegativeOrigin() {
        let f = PanelGeometry.frame(visibleFrame: NSRect(x: -1920, y: 0, width: 1920, height: 1055), height: 300)
        XCTAssertEqual(f, NSRect(x: -1920, y: 0, width: 1920, height: 300))
    }

    func testHeightNeverExceedsVisibleHeight() {
        let f = PanelGeometry.frame(visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 250), height: 300)
        XCTAssertEqual(f.height, 250)
    }
}
