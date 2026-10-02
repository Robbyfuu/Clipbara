import CloudKit
import SwiftData
import XCTest

@MainActor
final class LocalChangeTrackerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var tracker: LocalChangeTracker!
    private var changes: [CKSyncEngine.PendingRecordZoneChange] = []

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        changes = []
        tracker = LocalChangeTracker(context: context) { [unowned self] in self.changes += $0 }
    }

    private func makeClip(_ type: ContentType = .plainText, data: Data = Data("x".utf8), hash: String = "h") -> ClipboardItem {
        ClipboardItem(contentType: type, rawData: data, textContent: "x", contentHash: hash)
    }

    private func save(_ id: UUID) -> CKSyncEngine.PendingRecordZoneChange {
        .saveRecord(SyncRecordMapper.recordID(for: id))
    }

    func testInsertClipQueuesSave() throws {
        let clip = makeClip()
        context.insert(clip)
        try context.save()
        XCTAssertEqual(changes, [save(clip.id)])
    }

    func testRenameClipQueuesSave() throws {
        let clip = makeClip()
        context.insert(clip)
        try context.save()
        changes = []
        clip.userTitle = "renamed"
        try context.save()
        XCTAssertEqual(changes, [save(clip.id)])
    }

    func testDeleteClipQueuesDelete() throws {
        let clip = makeClip()
        context.insert(clip)
        try context.save()
        changes = []
        let id = clip.id
        context.delete(clip)
        try context.save()
        XCTAssertEqual(changes, [.deleteRecord(SyncRecordMapper.recordID(for: id))])
    }

    func testInsertPinboardQueuesSave() throws {
        let board = Pinboard(name: "b")
        context.insert(board)
        try context.save()
        XCTAssertEqual(changes, [save(board.id)])
    }

    func testInsertEntryQueuesSave() throws {
        let clip = makeClip()
        let board = Pinboard(name: "b")
        context.insert(clip)
        context.insert(board)
        try context.save()
        changes = []
        let entry = PinboardEntry(clipboardItem: clip, pinboard: board)
        context.insert(entry)
        try context.save()
        XCTAssertTrue(changes.contains(save(entry.id)))
    }

    func testFileURLClipQueuesNothing() throws {
        context.insert(makeClip(.fileURL))
        try context.save()
        XCTAssertTrue(changes.isEmpty)
    }

    func testOversizedClipQueuesNothing() throws {
        context.insert(makeClip(data: Data(count: 20_971_521)))
        try context.save()
        XCTAssertTrue(changes.isEmpty)
    }

    func testEntryForFileURLClipQueuesNothing() throws {
        let clip = makeClip(.fileURL)
        let board = Pinboard(name: "b")
        context.insert(clip)
        context.insert(board)
        try context.save()
        changes = []
        let entry = PinboardEntry(clipboardItem: clip, pinboard: board)
        context.insert(entry)
        try context.save()
        XCTAssertFalse(changes.contains(save(entry.id)))
        XCTAssertFalse(changes.contains(save(clip.id)))
    }

    func testExcludedAppQueuesNothing() throws {
        context.insert(ExcludedApp(bundleId: "com.x", appName: "X"))
        try context.save()
        XCTAssertTrue(changes.isEmpty)
    }

    func testSuppressedSaveQueuesNothing() throws {
        let clip = makeClip()
        context.insert(clip)
        try tracker.suppressing([clip.id]) { try context.save() }
        XCTAssertTrue(changes.isEmpty)
    }

    func testSuppressionCoversOnlyListedIDs() throws {
        let a = makeClip(hash: "a"), b = makeClip(hash: "b")
        context.insert(a)
        context.insert(b)
        try context.save()
        changes = []
        a.userTitle = "a"
        b.userTitle = "b"
        try tracker.suppressing([a.id]) { try context.save() }
        XCTAssertEqual(changes, [save(b.id)])
    }

    func testChangeThenDeleteQueuesDelete() throws {
        let clip = makeClip()
        context.insert(clip)
        try context.save()
        changes = []
        let id = clip.id
        clip.userTitle = "x"
        context.delete(clip)
        try context.save()
        XCTAssertEqual(changes, [.deleteRecord(SyncRecordMapper.recordID(for: id))])
    }

    func testInsertThenDeleteInSameSaveQueuesNothing() throws {
        let clip = makeClip()
        context.insert(clip)
        context.delete(clip)
        try context.save()
        XCTAssertTrue(changes.isEmpty)
    }
}
