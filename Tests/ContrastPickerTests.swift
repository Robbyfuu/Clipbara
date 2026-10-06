import XCTest

final class ContrastPickerTests: XCTestCase {
    private let white = RGB(r: 1, g: 1, b: 1)
    private let black = RGB(r: 0, g: 0, b: 0)
    private let yellow = RGB(r: 250 / 255, g: 210 / 255, b: 40 / 255)
    private let navy = RGB(r: 0, g: 0, b: 128 / 255)
    private let midGray = RGB(r: 128 / 255, g: 128 / 255, b: 128 / 255)

    func testRatioMatchesWCAG() {
        XCTAssertEqual(ContrastPicker.ratio(white, black), 21, accuracy: 0.01)
        XCTAssertEqual(ContrastPicker.ratio(black, white), 21, accuracy: 0.01, "order does not matter")
        XCTAssertEqual(ContrastPicker.ratio(midGray, midGray), 1, accuracy: 0.001)
    }

    func testDarkTextOnYellow() {
        XCTAssertEqual(ContrastPicker.textColor(on: yellow), .dark)
        XCTAssertGreaterThan(ContrastPicker.ratio(ContrastPicker.darkInk, yellow), ContrastPicker.ratio(white, yellow))
    }

    func testLightTextOnNavy() {
        XCTAssertEqual(ContrastPicker.textColor(on: navy), .light)
    }

    /// Mid-gray is the closest call: dark ink still wins, at about 4.4:1 against white's 3.9:1.
    func testDarkTextOnMidGray() {
        XCTAssertEqual(ContrastPicker.textColor(on: midGray), .dark)
    }

    func testWhiteAndBlackIcons() {
        XCTAssertEqual(ContrastPicker.textColor(on: white), .dark)
        XCTAssertEqual(ContrastPicker.textColor(on: black), .light)
    }

    /// Whatever the app color, the picked tone reads at 4:1 or better: every gray level, and the fixtures.
    func testPickedToneIsAlwaysReadable() {
        let grays = (0...255).map { RGB(r: Double($0) / 255, g: Double($0) / 255, b: Double($0) / 255) }
        for fill in grays + [yellow, navy, white, black] {
            let ink = ContrastPicker.textColor(on: fill) == .dark ? ContrastPicker.darkInk : white
            XCTAssertGreaterThanOrEqual(ContrastPicker.ratio(ink, fill), 4, fill.hex)
        }
    }
}
