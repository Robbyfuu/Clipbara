import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class PasteboardImageTests: XCTestCase {
    private func image(width: Int, height: Int, as type: NSBitmapImageRep.FileType) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return type == .tiff ? rep.tiffRepresentation! : rep.representation(using: type, properties: [:])!
    }

    func testPNGPassesThroughUnchanged() {
        let png = image(width: 40, height: 20, as: .png)
        let out = PasteboardImage.payload(from: png, maxPixels: 2048)
        XCTAssertEqual(out?.data, png)
        XCTAssertEqual(out?.uti, UTType.png.identifier)
    }

    func testJPEGPassesThroughUnchanged() {
        let jpeg = image(width: 40, height: 20, as: .jpeg)
        let out = PasteboardImage.payload(from: jpeg, maxPixels: 2048)
        XCTAssertEqual(out?.data, jpeg)
        XCTAssertEqual(out?.uti, UTType.jpeg.identifier)
    }

    func testTIFFIsTranscodedToPNGWithinLimit() throws {
        let out = try XCTUnwrap(PasteboardImage.payload(from: image(width: 3000, height: 1500, as: .tiff), maxPixels: 2048))
        XCTAssertEqual(out.uti, UTType.png.identifier)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(out.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        XCTAssertEqual(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width, 2048)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(PasteboardImage.payload(from: Data("not an image".utf8), maxPixels: 2048))
    }
}
