import SwiftData
import XCTest

@MainActor
final class SaveTextTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    private func items() throws -> [ClipboardItem] {
        try context.fetch(FetchDescriptor<ClipboardItem>())
    }

    func testSavesNewTextFromShortcuts() throws {
        XCTAssertEqual(SaveText.save(text: "héllo", in: context, now: now), .saved)
        XCTAssertFalse(context.hasChanges, "saved, not left for autosave")
        let item = try XCTUnwrap(try items().first)
        XCTAssertEqual(try items().count, 1)
        XCTAssertEqual(item.contentType, .plainText)
        XCTAssertEqual(item.textContent, "héllo")
        XCTAssertEqual(item.rawData, Data("héllo".utf8))
        XCTAssertEqual(item.contentHash, ClipCapture.hash(Data("héllo".utf8)))
        XCTAssertEqual(item.sourceAppName, "Shortcuts")
        XCTAssertEqual(item.copiedAt, now)
    }

    func testLinkTextSavesAsURL() throws {
        XCTAssertEqual(SaveText.save(text: "https://copyd.app/x", in: context, now: now), .saved)
        XCTAssertEqual(try items().first?.contentType, .url)
    }

    func testSameTextWithin10sIsDuplicate() throws {
        XCTAssertEqual(SaveText.save(text: "a", in: context, now: now), .saved)
        XCTAssertEqual(SaveText.save(text: "a", in: context, now: now.addingTimeInterval(5)), .duplicate)
        XCTAssertEqual(try items().count, 1)
        XCTAssertEqual(SaveText.save(text: "a", in: context, now: now.addingTimeInterval(11)), .saved)
        XCTAssertEqual(try items().count, 2)
    }

    func testEmptyTextIsNotSaved() throws {
        XCTAssertEqual(SaveText.save(text: "", in: context, now: now), .empty)
        XCTAssertEqual(try items().count, 0)
    }

    func testSecretIsSavedAsSensitive() throws {
        XCTAssertEqual(SaveText.save(text: FakeSecret.stripe, in: context, now: now), .saved)
        XCTAssertEqual(SaveText.save(text: "plain", in: context, now: now), .saved)
        XCTAssertEqual(Set(try items().filter(\.isSensitive).map(\.textContent)), [FakeSecret.stripe])
    }
}
