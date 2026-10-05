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
        add("text", dt: 0); add("file:///tmp/a.pdf", type: .fileURL, dt: 20); add("a.pdf", type: .files, dt: 30)
        XCTAssertEqual(try LatestClip.newest(in: context)?.textContent, "text")
    }

    func testEmptyHistory() throws {
        XCTAssertNil(try LatestClip.newest(in: context))
        add("file:///tmp/a.pdf", type: .fileURL, dt: 0)
        XCTAssertNil(try LatestClip.newest(in: context), "file clips alone count as empty")
    }

    /// The Live Activity shows the newest clip that is not a secret; Shortcuts' Copy Last Clip still copies it.
    func testSkipsSecretsUnlessAsked() throws {
        add("older", dt: 0)
        add(FakeSecret.stripe, dt: 10)
        try context.fetch(FetchDescriptor<ClipboardItem>()).first { $0.textContent == FakeSecret.stripe }?.isSensitive = true
        XCTAssertEqual(try LatestClip.newest(in: context)?.textContent, "older")
        XCTAssertEqual(try LatestClip.newest(in: context, includingSecrets: true)?.textContent, FakeSecret.stripe)
    }
}
