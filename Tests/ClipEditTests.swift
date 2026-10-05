import CloudKit
import SwiftData
import XCTest

/// Review focus 4: an edit changes `contentHash`, and sync carries it as an update of the same clip, never a new one.
@MainActor
final class ClipEditTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var changes: [CKSyncEngine.PendingRecordZoneChange] = []
    private var tracker: LocalChangeTracker?
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return container.mainContext
    }

    private func tracked() throws -> ModelContext {
        let context = try makeContext()
        tracker = LocalChangeTracker(context: context) { [unowned self] in self.changes += $0 }
        return context
    }

    private func text(_ text: String, type: ContentType = .plainText) -> ClipboardItem {
        ClipboardItem(contentType: type, rawData: Data(text.utf8), textContent: text,
                      contentHash: ClipCapture.hash(Data(text.utf8)))
    }

    /// A clip in `context`, saved.
    private func saved(_ clip: ClipboardItem, in context: ModelContext) throws -> ClipboardItem {
        context.insert(clip)
        try context.save()
        return clip
    }

    private func save(_ id: UUID) -> CKSyncEngine.PendingRecordZoneChange { .saveRecord(SyncRecordMapper.recordID(for: id)) }
    private func delete(_ id: UUID) -> CKSyncEngine.PendingRecordZoneChange { .deleteRecord(SyncRecordMapper.recordID(for: id)) }

    // MARK: Saving an edit

    func testEditStoresPlainTextAndANewHash() throws {
        let context = try makeContext()
        let clip = try saved(ClipboardItem(contentType: .richText, rawData: Data(#"{\rtf1 Hi}"#.utf8), textContent: "Hi",
                                           contentHash: "rtf"), in: context)
        XCTAssertTrue(clip.saveEdit("Hello\r\nthere 👋", in: context))
        XCTAssertFalse(context.hasChanges, "saved")
        XCTAssertEqual(clip.contentType, .plainText)
        XCTAssertEqual(clip.textContent, "Hello\r\nthere 👋")
        XCTAssertEqual(clip.rawData, Data("Hello\r\nthere 👋".utf8))
        XCTAssertEqual(clip.contentHash, ClipCapture.hash(Data("Hello\r\nthere 👋".utf8)))
    }

    func testEditToALinkStoresALink() throws {
        let context = try makeContext()
        let clip = try saved(text("draft"), in: context)
        XCTAssertTrue(clip.saveEdit("https://copyd.app/a?b=1", in: context))
        XCTAssertEqual(clip.contentType, .url)
    }

    func testUnchangedOrEmptyEditChangesNothing() throws {
        let context = try makeContext()
        let clip = try saved(text("same"), in: context)
        XCTAssertFalse(clip.saveEdit("same", in: context))
        XCTAssertFalse(clip.saveEdit("", in: context))
        XCTAssertEqual(clip.textContent, "same")
        XCTAssertEqual(clip.contentHash, ClipCapture.hash(Data("same".utf8)))
    }

    func testOnlyTextLikeClipsThatAreNotSecretsAreEditable() throws {
        for type in [ContentType.plainText, .richText, .html, .url] {
            XCTAssertTrue(text("x", type: type).isEditable, "\(type)")
        }
        for type in [ContentType.image, .files, .fileURL, .color, .unknown] {
            XCTAssertFalse(text("x", type: type).isEditable, "\(type)")
        }
        let context = try makeContext()
        let secret = text(FakeSecret.stripe)
        secret.isSensitive = true
        context.insert(secret)
        XCTAssertFalse(secret.isEditable, "editing would show the secret")
        XCTAssertFalse(secret.saveEdit("just a note", in: context), "nor saves")
        XCTAssertTrue(secret.isSensitive, "an edit never clears the flag")
        XCTAssertEqual(secret.textContent, FakeSecret.stripe)
    }

    // MARK: Edits that turn out to be secrets

    func testUnsyncedClipThatBecomesASecretIsFlaggedInPlace() throws {
        let context = try tracked()
        let clip = try saved(text("note"), in: context)
        changes = []

        XCTAssertTrue(clip.saveEdit(FakeSecret.stripe, in: context, protects: true))
        let clips = try context.fetch(FetchDescriptor<ClipboardItem>())
        XCTAssertEqual(clips.map(\.id), [clip.id])
        XCTAssertTrue(clip.isSensitive, "flagged before the save")
        XCTAssertEqual(clip.textContent, FakeSecret.stripe)
        XCTAssertEqual(changes, [], "never uploads")
    }

    /// Flagging a synced clip would also stop its delete, and leave the old text on the server for good.
    func testSyncedClipThatBecomesASecretIsReplacedByALocalClip() throws {
        let context = try tracked()
        let clip = text("note")
        clip.userTitle = "Login"
        clip.isPinned = true
        let board = Pinboard(name: "Work")
        let entry = PinboardEntry(clipboardItem: clip, pinboard: board, displayOrder: 4)
        context.insert(clip)
        context.insert(board)
        context.insert(entry)
        try context.save()
        // What the engine stores once the server accepts them.
        try tracker?.suppressing([clip.id, board.id, entry.id]) {
            clip.syncSystemFields = Data([1])
            board.syncSystemFields = Data([2])
            entry.syncSystemFields = Data([3])
            try context.save()
        }
        let original = clip.id, originalEntry = entry.id
        changes = []

        XCTAssertTrue(clip.saveEdit(FakeSecret.stripe, in: context, now: t0, protects: true))
        XCTAssertFalse(context.hasChanges, "one save")

        let clips = try context.fetch(FetchDescriptor<ClipboardItem>())
        XCTAssertEqual(clips.count, 1)
        let secret = try XCTUnwrap(clips.first)
        XCTAssertNotEqual(secret.id, original, "a new clip")
        XCTAssertTrue(secret.isSensitive)
        XCTAssertEqual(secret.textContent, FakeSecret.stripe)
        XCTAssertEqual(secret.contentHash, ClipCapture.hash(Data(FakeSecret.stripe.utf8)))
        XCTAssertEqual(secret.copiedAt, t0)
        XCTAssertNil(secret.syncSystemFields)
        XCTAssertEqual(secret.userTitle, "Login")
        XCTAssertTrue(secret.isPinned)

        // Secrets may sit on a pinboard (local only), so the entry moves to the new clip, under a new id.
        let entries = try context.fetch(FetchDescriptor<PinboardEntry>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotEqual(entries.first?.id, originalEntry)
        XCTAssertEqual(entries.first?.clipboardItem?.id, secret.id)
        XCTAssertEqual(entries.first?.pinboard?.id, board.id)
        XCTAssertEqual(entries.first?.displayOrder, 4)

        XCTAssertTrue(changes.contains(delete(original)), "the old text leaves iCloud: \(changes)")
        XCTAssertTrue(changes.contains(delete(originalEntry)), "\(changes)")
        XCTAssertTrue(changes.allSatisfy { $0 == delete(original) || $0 == delete(originalEntry) || $0 == save(board.id) },
                      "nothing of the secret uploads: \(changes)")
        XCTAssertEqual(try RemoteApplier.uploadableIDs(in: context, onlyUnconfirmed: false), [board.id])
    }

    func testEditWhileNotProtectingStaysNormal() throws {
        let context = try makeContext()
        let clip = try saved(text("note"), in: context)
        XCTAssertTrue(clip.saveEdit(FakeSecret.stripe, in: context, protects: false))
        XCTAssertFalse(clip.isSensitive)
    }

    // MARK: Sync

    func testEditedClipRoundTripsAsAnUpdate() throws {
        let dir = FileManager.default.temporaryDirectory
        // The Mac sends the original; the iPhone applies it.
        let mac = try tracked()
        let clip = text("draft")
        clip.userTitle = "Note"
        mac.insert(clip)
        try mac.save()
        let sent = CKRecord(recordType: SyncRecordMapper.clipType, recordID: SyncRecordMapper.recordID(for: clip.id))
        try SyncRecordMapper.populate(sent, from: clip.snapshot, assetDirectory: dir)
        try tracker?.suppressing([clip.id]) {
            clip.syncSystemFields = SyncRecordMapper.archive(sent)
            try mac.save()
        }
        let phone = try makeContext()
        let applier = RemoteApplier(context: phone) { _ in false }
        _ = applier.apply(clips: [try SyncRecordMapper.clip(from: sent)], pinboards: [], entries: [], deletions: [],
                          systemFields: [:])
        try phone.save()

        // The Mac edits it.
        changes = []
        XCTAssertTrue(clip.saveEdit("final text", in: mac))
        XCTAssertEqual(changes, [save(clip.id)], "a save of the same record")

        // The send is built on the cached record, and carries the new content.
        let (record, serverHash) = SyncRecordMapper.record(SyncRecordMapper.clipType, sent.recordID,
                                                           systemFields: clip.syncSystemFields)
        XCTAssertEqual(serverHash, ClipCapture.hash(Data("draft".utf8)))
        try SyncRecordMapper.populate(record, from: clip.snapshot, assetDirectory: dir, serverContentHash: serverHash)
        XCTAssertEqual(record.encryptedValues["textContent"] as String?, "final text")
        XCTAssertEqual(record.encryptedValues["rawData"] as Data?, Data("final text".utf8))

        // The iPhone updates its clip in place.
        let out = applier.apply(clips: [try SyncRecordMapper.clip(from: record)], pinboards: [], entries: [],
                                deletions: [], systemFields: [:])
        try phone.save()
        let clips = try phone.fetch(FetchDescriptor<ClipboardItem>())
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.id, clip.id)
        XCTAssertEqual(clips.first?.textContent, "final text")
        XCTAssertEqual(clips.first?.contentHash, ClipCapture.hash(Data("final text".utf8)))
        XCTAssertEqual(clips.first?.userTitle, "Note")
        XCTAssertEqual(out.inserted, [], "an update, not a new clip")
        XCTAssertEqual(out.deletes, [], "nothing merged away")
        XCTAssertTrue(out.arrivals.isEmpty, "never announced")
    }
}
