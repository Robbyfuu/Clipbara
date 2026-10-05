import CloudKit
import SwiftData
import XCTest

/// Review focus 1: a secret never reaches CloudKit, through any save, delete, pin, edit, pinboard add or merge.
@MainActor
final class SensitiveSyncTests: XCTestCase {
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

    private func secret(id: UUID = UUID(), at date: Date = Date()) -> ClipboardItem {
        let clip = ClipboardItem(contentType: .plainText, rawData: Data(FakeSecret.stripe.utf8),
                                 textContent: FakeSecret.stripe, contentHash: "secret")
        clip.id = id
        clip.copiedAt = date
        clip.isSensitive = true
        return clip
    }

    private func save(_ id: UUID) -> CKSyncEngine.PendingRecordZoneChange {
        .saveRecord(SyncRecordMapper.recordID(for: id))
    }

    func testSensitiveClipNeverUploads() throws {
        let clip = secret()
        let board = Pinboard(name: "Keys")
        context.insert(clip)
        context.insert(board)
        try context.save()
        XCTAssertEqual(changes, [save(board.id)], "the tracker skips the secret's insert")

        XCTAssertFalse(SyncRecordMapper.isEligible(contentType: "plainText", byteCount: 32, isSensitive: true))
        XCTAssertTrue(SyncRecordMapper.isEligible(contentType: "plainText", byteCount: 32, isSensitive: false))
        XCTAssertFalse(clip.isSyncEligible, "the batch builder drops it, whatever queued it")

        XCTAssertEqual(try RemoteApplier.uploadableIDs(in: context, onlyUnconfirmed: false), [board.id], "queueEverything")
        XCTAssertEqual(try RemoteApplier.uploadableIDs(in: context, onlyUnconfirmed: true), [board.id], "restart re-queue")

        changes = []
        clip.isPinned = true
        try context.save()
        clip.userTitle = "Stripe"
        clip.textContent = FakeSecret.stripe + "x"
        clip.contentHash = "edited"
        try context.save()
        let entry = PinboardEntry(clipboardItem: clip, pinboard: board)
        context.insert(entry)
        try context.save()
        XCTAssertTrue(changes.allSatisfy { $0 == save(board.id) }, "pin, edit and pinboard add queue nothing of the secret: \(changes)")
        XCTAssertEqual(try RemoteApplier.uploadableIDs(in: context, onlyUnconfirmed: false), [board.id],
                       "nor does its pinboard entry")
    }

    /// The sweep deletes what never uploaded, so it must not send a delete for the clip or its pinboard entry.
    func testSweepSendsNoCloudKitDelete() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = secret(at: now.addingTimeInterval(-301))
        let fresh = secret(at: now.addingTimeInterval(-10))
        let plain = ClipboardItem(contentType: .plainText, rawData: Data("hi".utf8), textContent: "hi", contentHash: "hi")
        plain.copiedAt = now.addingTimeInterval(-3_600)
        let board = Pinboard(name: "Keys")
        [old, fresh, plain].forEach(context.insert)
        context.insert(board)
        context.insert(PinboardEntry(clipboardItem: old, pinboard: board))
        try context.save()
        changes = []

        XCTAssertEqual(SecretSweeper.sweep(in: context, now: now, after: 300), 1)
        XCTAssertFalse(context.hasChanges, "saved")
        XCTAssertEqual(Set(try context.fetch(FetchDescriptor<ClipboardItem>()).map(\.id)), [fresh.id, plain.id])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PinboardEntry>()), 0, "its pinboard entry goes too")
        XCTAssertFalse(changes.contains { if case .deleteRecord = $0 { true } else { false } }, "\(changes)")
    }

    func testDeletingASecretByHandSendsNoDelete() throws {
        let clip = secret()
        context.insert(clip)
        try context.save()
        context.delete(clip)
        try context.save()
        XCTAssertEqual(changes, [])
    }

    func testSweepNeverDeletesWhenSetToNever() throws {
        context.insert(secret(at: .distantPast))
        try context.save()
        XCTAssertEqual(SecretSweeper.sweep(in: context, now: Date(), after: nil), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ClipboardItem>()), 1)
    }

    /// A backup imported on another Mac would upload the secret from there, so the export leaves it out.
    func testBackupLeavesSecretsOut() throws {
        let clip = secret()
        let plain = ClipboardItem(contentType: .plainText, rawData: Data("hi".utf8), textContent: "hi", contentHash: "hi")
        let board = Pinboard(name: "Keys")
        [clip, plain].forEach(context.insert)
        context.insert(board)
        context.insert(PinboardEntry(clipboardItem: clip, pinboard: board))
        try context.save()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(TransferDocument.self, from: try TransferService.exportDocument(context: context))
        XCTAssertEqual(doc.items.map(\.id), [plain.id])
        XCTAssertEqual(doc.entries.count, 0)
        XCTAssertEqual(doc.pinboards.map(\.id), [board.id])
    }

    /// A remote copy of the same content (Universal Clipboard to a Mac without protection) never merges with the
    /// local secret: either way round, the merge would queue a save or a delete of the secret's id.
    func testRemoteDuplicateNeverMergesWithASecret() throws {
        let id = { (n: Int) in UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        let now = Date()
        let local = secret(id: id(2), at: now)
        context.insert(local)
        try context.save()
        let remote = { (n: Int) in
            ClipSnapshot(id: id(n), contentType: "plainText", rawData: Data(FakeSecret.stripe.utf8),
                         textContent: FakeSecret.stripe, contentHash: "secret", copiedAt: now, isPinned: false)
        }
        let out = RemoteApplier(context: context) { _ in false }
            .apply(clips: [remote(1), remote(3)], pinboards: [], entries: [], deletions: [], systemFields: [:])
        try tracker.suppressing(out.touched) { try context.save() }
        XCTAssertFalse(out.saves.contains(local.id))
        XCTAssertFalse(out.deletes.contains(local.id))
        XCTAssertTrue(try context.fetch(FetchDescriptor<ClipboardItem>()).contains { $0.id == local.id && $0.isSensitive })
    }
}
