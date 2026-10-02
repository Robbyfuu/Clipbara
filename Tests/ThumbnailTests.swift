import AppKit
import XCTest

final class ThumbnailTests: XCTestCase {
    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func testLandscapeImageFitsMaxSize() {
        let out = Thumbnail.png(from: png(width: 1000, height: 500))!
        XCTAssertEqual(NSImage(data: out)!.size, NSSize(width: 320, height: 160))
    }

    func testSmallImageIsNotUpscaled() {
        let out = Thumbnail.png(from: png(width: 100, height: 80))!
        XCTAssertEqual(NSImage(data: out)!.size, NSSize(width: 100, height: 80))
    }

    func testInvalidDataReturnsNil() {
        XCTAssertNil(Thumbnail.png(from: Data("x".utf8)))
    }
}
