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

    // MARK: - Copied files are read later, off the main thread

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CopydTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testClassifyLeavesCopiedFilesUnread() throws {
        let file = try tempDirectory().appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])

        let content = try XCTUnwrap(ContentTypeClassifier().classify(board))
        XCTAssertEqual(content.contentType, .fileURL, "the main thread only gets the local file clip")
        XCTAssertEqual(content.fileURLs?.map(\.lastPathComponent), ["notes.txt"])

        let files = content.readingFiles()
        XCTAssertEqual(files.contentType, .files)
        XCTAssertEqual(files.textContent, "notes.txt")
        XCTAssertEqual(try FileBundle.decode(files.rawData).map(\.data), [Data("hello".utf8)])
    }

    func testUnreadableFilesKeepTheFileURLClip() throws {
        let folder = try tempDirectory()
        board.clearContents()
        board.writeObjects([folder as NSURL])
        board.setData(Data([1]), forType: remote)

        let kept = try XCTUnwrap(ContentTypeClassifier().classify(board)).readingFiles()
        XCTAssertEqual(kept.contentType, .fileURL, "a folder stays a local path")
        XCTAssertEqual(kept.textContent, folder.lastPathComponent)
        XCTAssertTrue(kept.fromUniversalClipboard)
    }

    func testReadFilesKeepTheUniversalClipboardFlag() throws {
        let file = try tempDirectory().appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        board.clearContents()
        board.writeObjects([file as NSURL])
        board.setData(Data([1]), forType: remote)

        let files = try XCTUnwrap(ContentTypeClassifier().classify(board)).readingFiles()
        XCTAssertEqual(files.contentType, .files)
        XCTAssertTrue(files.fromUniversalClipboard)
    }
}
