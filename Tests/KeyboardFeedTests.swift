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
        add("file:///x", type: .fileURL, dt: 5); add("t", dt: 1)
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

    func testFeedCarriesSourceAppName() throws {
        add("a", dt: 1, source: "Safari"); add("b", dt: 0)
        XCTAssertEqual(try KeyboardFeed.items(in: context, mode: .recent).map(\.sourceAppName), ["Safari", nil])
    }
}
