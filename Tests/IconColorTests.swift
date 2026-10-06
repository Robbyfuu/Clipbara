import XCTest

final class IconColorTests: XCTestCase {
    private let side = 64

    /// A `side`×`side` premultiplied RGBA bitmap: `paint(x, y)` gives each pixel's bytes.
    private func bitmap(_ paint: (Int, Int) -> [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for y in 0..<side { for x in 0..<side { out += paint(x, y) } }
        return out
    }

    private func assertColor(_ c: RGB, _ r: Double, _ g: Double, _ b: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.r, r, accuracy: 0.01, "red", file: file, line: line)
        XCTAssertEqual(c.g, g, accuracy: 0.01, "green", file: file, line: line)
        XCTAssertEqual(c.b, b, accuracy: 0.01, "blue", file: file, line: line)
    }

    func testSolidRed() {
        let c = IconColor.dominant(rgba: bitmap { _, _ in [255, 0, 0, 255] }, width: side, height: side)
        assertColor(c, 1, 0, 0)
        XCTAssertEqual(c.hex, "#FF0000")
    }

    /// A white glyph over most of a blue tile: near-white is ignored while enough blue remains.
    func testWhiteGlyphOnBlueIsBlue() {
        let rgba = bitmap { x, _ in x < side * 6 / 10 ? [255, 255, 255, 255] : [20, 90, 220, 255] }
        assertColor(IconColor.dominant(rgba: rgba, width: side, height: side), 20 / 255, 90 / 255, 220 / 255)
    }

    /// Transparent padding (alpha 0, zero bytes) around a green square never reads as black.
    func testTransparentPaddingIsIgnored() {
        let rgba = bitmap { x, y in
            (16..<48).contains(x) && (16..<48).contains(y) ? [30, 180, 60, 255] : [0, 0, 0, 0]
        }
        assertColor(IconColor.dominant(rgba: rgba, width: side, height: side), 30 / 255, 180 / 255, 60 / 255)
    }

    func testBlackGlyphOnYellowIsYellow() {
        let rgba = bitmap { x, y in (8..<40).contains(x) && (8..<40).contains(y) ? [0, 0, 0, 255] : [250, 210, 40, 255] }
        assertColor(IconColor.dominant(rgba: rgba, width: side, height: side), 250 / 255, 210 / 255, 40 / 255)
    }

    /// An all-white icon has nothing left once near-white is ignored, so white itself wins.
    func testAllWhiteStaysWhite() {
        assertColor(IconColor.dominant(rgba: bitmap { _, _ in [255, 255, 255, 255] }, width: side, height: side), 1, 1, 1)
    }

    /// The most frequent 4-bit bucket wins, and its pixels are averaged.
    func testMostFrequentBucketIsAveraged() {
        // Two pixels per column pattern: the 32×32 grid samples every other pixel of this 64-pixel bitmap.
        let rgba = bitmap { x, _ in
            switch (x / 2) % 4 {
            case 0: [200, 40, 40, 255]
            case 1: [204, 44, 44, 255]  // same bucket as 200, 40, 40
            case 2: [40, 40, 200, 255]
            default: [40, 200, 40, 255]
            }
        }
        assertColor(IconColor.dominant(rgba: rgba, width: side, height: side), 202 / 255, 42 / 255, 42 / 255)
    }

    /// Premultiplied half-transparent pixels count with their real color.
    func testPremultipliedPixelsAreUnpremultiplied() {
        let rgba = bitmap { _, _ in [100, 0, 0, 200] }  // straight red ≈ 127
        assertColor(IconColor.dominant(rgba: rgba, width: side, height: side), 0.5, 0, 0)
    }

    func testFullyTransparentIsNeutralGray() {
        assertColor(IconColor.dominant(rgba: bitmap { _, _ in [0, 0, 0, 0] }, width: side, height: side), 0.5, 0.5, 0.5)
    }

    func testHexRoundTrip() {
        XCTAssertEqual(RGB(hex: "#1E90FF")?.hex, "#1E90FF")
        XCTAssertNil(RGB(hex: "blue"))
    }
}
