import SwiftData
import XCTest

@MainActor
final class PasteEventTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self, PasteEvent.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
    }

    private func events() throws -> [PasteEvent] {
        try context.fetch(FetchDescriptor<PasteEvent>(sortBy: [SortDescriptor(\.at)]))
    }

    private func makeClip() -> ClipboardItem {
        let clip = ClipboardItem(contentType: .plainText, rawData: Data("x".utf8), textContent: "x", contentHash: "h")
        context.insert(clip)
        return clip
    }

    func testRecordsOneEventPerClip() throws {
        let ids = [UUID(), UUID()]
        PasteEvent.record(ids, app: "com.apple.Safari", in: context)
        XCTAssertEqual(Set(try events().map(\.clipID)), Set(ids))
        XCTAssertEqual(try events().map(\.appBundleID), ["com.apple.Safari", "com.apple.Safari"])
    }

    func testKeepsTheLast2000Events() throws {
        let start = Date(timeIntervalSince1970: 0)
        for i in 0..<2_000 {
            context.insert(PasteEvent(clipID: UUID(), appBundleID: "a", at: start.addingTimeInterval(Double(i))))
        }
        try context.save()
        let oldest = try XCTUnwrap(try events().first?.clipID)
        let new = UUID()
        PasteEvent.record([new], app: "b", in: context)
        let kept = try events()
        XCTAssertEqual(kept.count, 2_000)
        XCTAssertFalse(kept.contains { $0.clipID == oldest })
        XCTAssertEqual(kept.last?.clipID, new)
    }

    /// Whatever deletes the clip (the panel, Clear History, the history limit, sync), its events go with it.
    func testDeletingAClipDeletesItsEvents() async throws {
        PasteEvent.removeWithClips(in: context)
        let gone = makeClip(), kept = makeClip()
        try context.save()
        PasteEvent.record([gone.id, kept.id], app: "a", in: context)
        context.delete(gone)
        try context.save()
        // Removed on the next main actor turn, after the save that deleted the clip.
        for _ in 0..<50 where (try? events().count) != 1 { await Task.yield() }
        XCTAssertEqual(try events().map(\.clipID), [kept.id])
    }
}
