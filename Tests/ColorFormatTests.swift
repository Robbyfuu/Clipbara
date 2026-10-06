import XCTest

final class ColorFormatTests: XCTestCase {
    func testRGBString() {
        XCTAssertEqual(ColorFormat.rgbString(hex: "#3478F6"), "RGB 52, 120, 246")
        XCTAssertEqual(ColorFormat.rgbString(hex: " 3478f6\n"), "RGB 52, 120, 246")
        XCTAssertEqual(ColorFormat.rgbString(hex: "#000000"), "RGB 0, 0, 0")
        XCTAssertNil(ColorFormat.rgbString(hex: "#34F"))
        XCTAssertNil(ColorFormat.rgbString(hex: "#GGGGGG"))
        XCTAssertNil(ColorFormat.rgbString(hex: "blue"))
    }
}
