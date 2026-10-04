import AppKit
import XCTest

final class ContentTypeClassifierTests: XCTestCase {
    private let board = NSPasteboard(name: NSPasteboard.Name("CopydTests-\(UUID().uuidString)"))
    private let remote = NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")

    override func tearDown() {
        board.releaseGlobally()
    }

    private func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// Universal Clipboard marks what it brings from another device: the user's own iPhone copy, which the iPhone
    /// must not announce back. Every content type carries the flag.
    func testUniversalClipboardCopyIsFlagged() throws {
        board.declareTypes([.string, remote], owner: nil)
        board.setString("from my iPhone", forType: .string)
        board.setData(Data([1]), forType: remote)
        let text = try XCTUnwrap(ContentTypeClassifier().classify(board))
        XCTAssertEqual(text.contentType, .plainText)
        XCTAssertTrue(text.fromUniversalClipboard)

        board.declareTypes([.png, remote], owner: nil)
        board.setData(try png(), forType: .png)
        board.setData(Data([1]), forType: remote)
        let image = try XCTUnwrap(ContentTypeClassifier().classify(board))
        XCTAssertEqual(image.contentType, .image)
        XCTAssertTrue(image.fromUniversalClipboard)
    }

    func testLocalCopyIsNotFlagged() throws {
        board.declareTypes([.string], owner: nil)
        board.setString("copied on this Mac", forType: .string)
        XCTAssertFalse(try XCTUnwrap(ContentTypeClassifier().classify(board)).fromUniversalClipboard)
    }
}
