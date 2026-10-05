import AppKit
import SwiftData
import XCTest

@MainActor
final class KeyboardFeedTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    @discardableResult
    private func add(_ text: String?, type: ContentType = .plainText, dt: TimeInterval = 0,
                     pinned: Bool = false, raw: Data = Data("raw".utf8), thumb: Data? = nil,
                     source: String? = nil) -> ClipboardItem {
        let item = ClipboardItem(contentType: type, rawData: raw, textContent: text, thumbnailData: thumb,
                                 sourceAppName: source, contentHash: UUID().uuidString)
        item.copiedAt = t0.addingTimeInterval(dt)
        item.isPinned = pinned
        context.insert(item)
        return item
    }

    func testRecentIsNewestFirst() throws {
        add("old", dt: 0); add("new", dt: 10); add("mid", dt: 5)
        let clips = try KeyboardFeed.items(in: context, mode: .recent)
        XCTAssertEqual(clips.map(\.preview), ["new", "mid", "old"])
    }

    func testPinnedOnlyReturnsPinned() throws {
        add("a", dt: 0, pinned: true); add("b", dt: 1); add("c", dt: 2, pinned: true)
        let clips = try KeyboardFeed.items(in: context, mode: .pinned)
        XCTAssertEqual(clips.map(\.preview), ["c", "a"])
    }

    func testLimitIs60() throws {
        for i in 0..<70 { add("t\(i)", dt: TimeInterval(i)) }
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .recent).count, 60)
    }

    func testFileClipsExcluded() throws {
        add("file:///x", type: .fileURL, dt: 5); add("a.pdf", type: .files, dt: 6, pinned: true); add("t", dt: 1)
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .pinned), [])
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .recent).map(\.preview), ["t"])
    }

    func testTextPreviewCappedAt300() throws {
        add("  " + String(repeating: "a", count: 500) + "\n", dt: 0)
        let p = try XCTUnwrap(KeyboardFeed.items(in: context, mode: .recent).first)
        XCTAssertEqual(p.preview, String(repeating: "a", count: 300))
        XCTAssertEqual(p.textByteCount, 503)
    }

    func testFeedCarriesThumbnailNotRawData() throws {
        let thumb = Data("thumb".utf8)
        add(nil, type: .image, raw: Data(repeating: 1, count: 1000), thumb: thumb)
        let clip = try XCTUnwrap(KeyboardFeed.items(in: context, mode: .recent).first)
        XCTAssertEqual(clip.thumbnail, thumb)
        XCTAssertEqual(clip.preview, "")
        XCTAssertEqual(clip.textByteCount, 0)
        XCTAssertFalse(Mirror(reflecting: clip).children.contains { $0.label == "rawData" })
    }

    func testUrlAndColorPreviewAreText() throws {
        add("https://a.b", type: .url, dt: 1); add("#FF0000", type: .color, dt: 0)
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .recent).map(\.preview), ["https://a.b", "#FF0000"])
    }

    func testClipboardCardFromCapturedText() throws {
        let text = "  " + String(repeating: "a", count: 500) + "\n"
        let card = KeyboardFeed.clipboardCard(try XCTUnwrap(ClipCapture.text(text)), now: t0)
        XCTAssertTrue(card.isClipboard)
        XCTAssertEqual(card.contentType, .plainText)
        XCTAssertEqual(card.preview, String(repeating: "a", count: 300), "same preview rule as the feed")
        XCTAssertEqual(card.textByteCount, 503)
        XCTAssertEqual(card.copiedAt, t0)
        XCTAssertNil(card.thumbnail)
        XCTAssertNotEqual(card.id, KeyboardFeed.clipboardCard(try XCTUnwrap(ClipCapture.text(text)), now: t0).id)
        add("stored")
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .recent).map(\.isClipboard), [false])
    }

    func testClipboardCardFromCapturedImageHasThumbnail() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let card = KeyboardFeed.clipboardCard(try XCTUnwrap(ClipCapture.image(png)), now: t0)
        XCTAssertEqual(card.contentType, .image)
        XCTAssertEqual(card.preview, "")
        XCTAssertEqual(card.thumbnail, Thumbnail.png(from: png))
        XCTAssertNotNil(card.thumbnail)
    }

    func testFeedCarriesSourceAppName() throws {
        add("a", dt: 1, source: "Safari"); add("b", dt: 0)
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .recent).map(\.sourceAppName), ["Safari", nil])
    }

    @discardableResult
    private func board(_ name: String, order: Int) -> Pinboard {
        let b = Pinboard(name: name, displayOrder: order)
        context.insert(b)
        return b
    }

    private func pin(_ item: ClipboardItem, to board: Pinboard, order: Int) {
        context.insert(PinboardEntry(clipboardItem: item, pinboard: board, displayOrder: order))
    }

    func testPinboardModeKeepsEntryOrder() throws {
        let b = board("Work", order: 0)
        let x = add("x", dt: 0), y = add("y", dt: 10), z = add("z", dt: 5)
        pin(y, to: b, order: 2); pin(x, to: b, order: 0); pin(z, to: b, order: 1)
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .pinboard(b.id)).map(\.preview), ["x", "z", "y"])
    }

    func testPinboardModeExcludesOtherBoards() throws {
        let a = board("A", order: 0), b = board("B", order: 1)
        pin(add("in-a"), to: a, order: 0); pin(add("in-b"), to: b, order: 0)
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .pinboard(a.id)).map(\.preview), ["in-a"])
    }

    func testPinboardModeExcludesFileClips() throws {
        let b = board("A", order: 0)
        pin(add("file:///x", type: .fileURL), to: b, order: 0); pin(add("t"), to: b, order: 1)
        pin(add("a.pdf", type: .files), to: b, order: 2)
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .pinboard(b.id)).map(\.preview), ["t"])
    }

    func testMissingPinboardReturnsEmpty() throws {
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .pinboard(UUID())), [])
    }

    func testBoardsInDisplayOrder() throws {
        let second = board("Second", order: 1), first = board("First", order: 0)
        let boards = try KeyboardFeed.boards(in: context)
        XCTAssertEqual(boards.map(\.name), ["First", "Second"])
        XCTAssertEqual(boards.map(\.id), [first.id, second.id])
        XCTAssertEqual(boards.first?.colorIndex, PinboardDot.index(for: first.id))
    }

    /// The keyboard and the widget (which reads this feed) never show a secret, in any mode.
    func testSecretsStayOutOfTheFeed() throws {
        let b = board("Keys", order: 0)
        let secret = add(FakeSecret.stripe, dt: 10, pinned: true)
        secret.isSensitive = true
        pin(secret, to: b, order: 0); pin(add("t", dt: 0, pinned: true), to: b, order: 1)
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .recent).map(\.preview), ["t"])
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .pinned).map(\.preview), ["t"])
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .pinboard(b.id)).map(\.preview), ["t"])
    }

    /// The keyboard's own capture of a secret shows masked; tapping it still inserts the real text.
    func testClipboardCardMasksASecret() throws {
        let card = KeyboardFeed.clipboardCard(try XCTUnwrap(ClipCapture.text(FakeSecret.stripe)), now: t0, protects: true)
        XCTAssertEqual(card.preview, "API key •••• p7dc")
        let open = KeyboardFeed.clipboardCard(try XCTUnwrap(ClipCapture.text(FakeSecret.stripe)), now: t0, protects: false)
        XCTAssertEqual(open.preview, FakeSecret.stripe, "Protect secrets is off")
    }

    // MARK: Insert as…

    func testCardsCarryTheirTransforms() throws {
        add("[1, 2]", dt: 2)
        add("png", type: .image, dt: 1)
        add("12345", dt: 0)
        let clips = try KeyboardFeed.items(in: context, mode: .recent)
        XCTAssertEqual(clips.map(\.transforms), [[.prettyJSON, .compactJSON], [], []],
                       "worked out from the whole text; none for images or text no transform changes")
    }

    /// Longer clips are copied, never inserted, so there is nothing to insert them as.
    func testNoTransformsAboveTheInsertLimit() throws {
        add(String(repeating: "a", count: PasteAction.insertByteLimit + 1))
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .recent).first?.transforms, [])
        add(String(repeating: "a", count: PasteAction.insertByteLimit), dt: 1)
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .recent).first?.transforms, [.upper, .title])
    }

    func testClipboardCardCarriesTheRealTextsTransforms() throws {
        let card = KeyboardFeed.clipboardCard(try XCTUnwrap(ClipCapture.text(FakeSecret.stripe)), now: t0, protects: true)
        XCTAssertEqual(card.transforms, [.upper, .lower, .title], "a masked secret still pastes as its real text")
    }
}
