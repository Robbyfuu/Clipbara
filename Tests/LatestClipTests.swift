import SwiftData
import XCTest

@MainActor
final class LatestClipTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    private func add(_ text: String, type: ContentType = .plainText, dt: TimeInterval) {
        let item = ClipboardItem(contentType: type, rawData: Data(text.utf8), textContent: text,
                                 contentHash: UUID().uuidString)
        item.copiedAt = t0.addingTimeInterval(dt)
        context.insert(item)
    }

    func testNewestByDate() throws {
        add("old", dt: 0); add("new", dt: 10); add("mid", dt: 5)
        XCTAssertEqual(try LatestClip.newest(in: context)?.textContent, "new")
    }

    func testSkipsFileClips() throws {
        add("text", dt: 0); add("file:///tmp/a.pdf", type: .fileURL, dt: 20)
        XCTAssertEqual(try LatestClip.newest(in: context)?.textContent, "text")
    }

    func testEmptyHistory() throws {
        XCTAssertNil(try LatestClip.newest(in: context))
        add("file:///tmp/a.pdf", type: .fileURL, dt: 0)
        XCTAssertNil(try LatestClip.newest(in: context), "file clips alone count as empty")
    }
}
