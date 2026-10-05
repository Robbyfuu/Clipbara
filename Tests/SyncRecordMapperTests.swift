import CloudKit
import SwiftData
import XCTest

final class SyncRecordMapperTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeClip(type: String = "plainText", bytes: Int = 10, full: Bool = true) -> ClipSnapshot {
        ClipSnapshot(
            id: UUID(), contentType: type, rawData: Data((0..<bytes).map { UInt8($0 % 251) }),
            textContent: full ? "text" : nil, userTitle: full ? "title" : nil,
            sourceAppName: full ? "App" : nil, sourceAppBundleId: full ? "com.app" : nil,
            contentHash: "hash", copiedAt: Date(timeIntervalSince1970: 1_700_000_000), isPinned: full,
            fromUniversalClipboard: full)
    }

    private func record(for clip: ClipSnapshot) -> CKRecord {
        CKRecord(recordType: SyncRecordMapper.clipType, recordID: SyncRecordMapper.recordID(for: clip.id))
    }

    func testClipRoundTripForEachSyncedType() throws {
        for type in ["plainText", "richText", "html", "image", "url", "color", "unknown"] {
            for full in [true, false] {
                let clip = makeClip(type: type, full: full)
                let rec = record(for: clip)
                try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
                XCTAssertEqual(try SyncRecordMapper.clip(from: rec), clip, "\(type) full=\(full)")
            }
        }
    }

    func testInlineAtExactlyLimit() throws {
        let clip = makeClip(bytes: SyncRecordMapper.inlineLimit)
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        XCTAssertNotNil(rec.encryptedValues["rawData"] as Data?)
        XCTAssertNil(rec["payload"])
    }

    func testAssetAboveLimit() throws {
        let clip = makeClip(bytes: SyncRecordMapper.inlineLimit + 1)
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        XCTAssertNotNil(rec["payload"] as CKAsset?)
        XCTAssertNotNil(rec.encryptedValues["assetKey"] as Data?)
        XCTAssertNil(rec.encryptedValues["rawData"] as Data?)
        XCTAssertEqual(try SyncRecordMapper.clip(from: rec).rawData, clip.rawData)
    }

    func testAssetFileIsNotPlaintext() throws {
        let clip = makeClip(bytes: SyncRecordMapper.inlineLimit + 1)
        try SyncRecordMapper.populate(record(for: clip), from: clip, assetDirectory: dir)
        let bytes = try Data(contentsOf: SyncRecordMapper.assetURL(for: clip.id, in: dir))
        XCTAssertNotEqual(bytes, clip.rawData)
    }

    func testEligibility() {
        XCTAssertFalse(SyncRecordMapper.isEligible(contentType: "fileURL", byteCount: 1, isSensitive: false))
        XCTAssertTrue(SyncRecordMapper.isEligible(contentType: "image", byteCount: 20_971_520, isSensitive: false))
        XCTAssertFalse(SyncRecordMapper.isEligible(contentType: "image", byteCount: 20_971_521, isSensitive: false))
        // A file bundle holds up to 10 files of 20 MB each, plus its manifest.
        XCTAssertTrue(SyncRecordMapper.isEligible(contentType: "files", byteCount: 30_000_000, isSensitive: false))
        XCTAssertTrue(SyncRecordMapper.isEligible(contentType: "files", byteCount: FileBundle.maxBundleBytes, isSensitive: false))
        XCTAssertFalse(SyncRecordMapper.isEligible(contentType: "files", byteCount: FileBundle.maxBundleBytes + 1, isSensitive: false))
    }

    func testFileClipRoundTripCarriesManifest() throws {
        let files: [(name: String, data: Data, uti: String)] = [
            (name: "a.pdf", data: Data(count: SyncRecordMapper.inlineLimit), uti: "com.adobe.pdf"),
            (name: "b.txt", data: Data("b".utf8), uti: "public.plain-text"),
        ]
        var clip = makeClip(type: "files")
        clip.rawData = try FileBundle.encode(files)
        clip.fileManifest = FileBundle.manifestJSON(clip.rawData)
        clip.textContent = "a.pdf, b.txt"
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)

        // The bundle goes up sealed, like a large image; the manifest rides encrypted on the record.
        XCTAssertNotNil(rec["payload"] as CKAsset?)
        XCTAssertNil(rec.encryptedValues["rawData"] as Data?)
        XCTAssertTrue(plainKeys(rec).isSubset(of: ["payload", "textPayload"]))
        let manifest = try JSONDecoder().decode([FileManifestEntry].self,
                                                from: try XCTUnwrap(rec.encryptedValues["fileManifest"] as Data?))
        XCTAssertEqual(manifest.map(\.name), ["a.pdf", "b.txt"])
        XCTAssertEqual(manifest.map(\.size), [SyncRecordMapper.inlineLimit, 1])
        XCTAssertEqual(manifest.map(\.uti), ["com.adobe.pdf", "public.plain-text"])

        // Read back, so the receiving device stores it and never opens the bundle to show the card.
        let decoded = try SyncRecordMapper.clip(from: rec)
        XCTAssertEqual(decoded.fileManifest, clip.fileManifest)
        XCTAssertEqual(decoded, clip)
    }

    func testOnlyFileClipsCarryAManifest() throws {
        let clip = makeClip(type: "image")
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        XCTAssertNil(rec.encryptedValues["fileManifest"] as Data?)
        XCTAssertNil(try SyncRecordMapper.clip(from: rec).fileManifest)
    }

    /// The Mac's mark for a copy Universal Clipboard brought from the iPhone: encrypted, 0/1 like `isPinned`.
    func testUniversalClipboardFlagRoundTrips() throws {
        for flag in [true, false] {
            var clip = makeClip(full: false)
            clip.fromUniversalClipboard = flag
            let rec = record(for: clip)
            try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
            XCTAssertEqual(rec.encryptedValues["fromUniversalClipboard"] as Int64?, flag ? 1 : 0)
            XCTAssertEqual(try SyncRecordMapper.clip(from: rec).fromUniversalClipboard, flag)
        }
    }

    /// Records saved before the field existed have none: they read as an ordinary copy.
    func testMissingUniversalClipboardFlagReadsAsFalse() throws {
        var clip = makeClip()
        clip.fromUniversalClipboard = true
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        rec.encryptedValues["fromUniversalClipboard"] = nil as Int64?
        XCTAssertFalse(try SyncRecordMapper.clip(from: rec).fromUniversalClipboard)
    }

    /// The text read in an image never syncs: each device reads its own, and none of it reaches CloudKit.
    @MainActor
    func testTextReadInAnImageIsNeverMapped() throws {
        let container = try ModelContainer(for: ClipboardItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let image = ClipboardItem(contentType: .image, rawData: Data([1, 2, 3]), contentHash: "h")
        container.mainContext.insert(image)
        image.ocrText = "Copyd OCR test"
        image.ocrDone = true
        let rec = record(for: image.snapshot)
        try SyncRecordMapper.populate(rec, from: image.snapshot, assetDirectory: dir)
        let keys = Set(rec.allKeys()).union(rec.encryptedValues.allKeys())
        XCTAssertTrue(keys.filter { $0.lowercased().contains("ocr") }.isEmpty, "\(keys)")
        for key in rec.encryptedValues.allKeys() {
            XCTAssertNotEqual(rec.encryptedValues[key] as? String, "Copyd OCR test", key)
        }
        let back = try SyncRecordMapper.clip(from: rec)
        XCTAssertNil(back.textContent)
        XCTAssertEqual(back, image.snapshot)
    }

    func testOnlyAllowedPlainKeys() throws {
        let clip = makeClip(bytes: SyncRecordMapper.inlineLimit + 1)
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        XCTAssertTrue(plainKeys(rec).isSubset(of: ["payload", "textPayload"]))

        var textClip = makeClip()
        textClip.textContent = String(repeating: "a", count: SyncRecordMapper.inlineLimit + 1)
        let trec = record(for: textClip)
        try SyncRecordMapper.populate(trec, from: textClip, assetDirectory: dir)
        XCTAssertEqual(plainKeys(trec), ["textPayload"])

        let board = PinboardSnapshot(id: UUID(), name: "n", displayOrder: 1, createdAt: Date())
        let brec = CKRecord(recordType: SyncRecordMapper.pinboardType, recordID: SyncRecordMapper.recordID(for: board.id))
        SyncRecordMapper.populate(brec, from: board)
        XCTAssertEqual(plainKeys(brec), [])

        let entry = EntrySnapshot(id: UUID(), clipID: UUID(), pinboardID: UUID(), displayOrder: 2, addedAt: Date())
        let erec = CKRecord(recordType: SyncRecordMapper.entryType, recordID: SyncRecordMapper.recordID(for: entry.id))
        SyncRecordMapper.populate(erec, from: entry)
        XCTAssertEqual(plainKeys(erec), ["clip", "pinboard"])
    }

    private func plainKeys(_ record: CKRecord) -> Set<String> {
        Set(record.allKeys()).subtracting(record.encryptedValues.allKeys())
    }

    func testEncryptedKeysMatchSpec() throws {
        let common: Set<String> = ["contentType", "textContent", "userTitle", "sourceAppName",
                                   "sourceAppBundleId", "contentHash", "copiedAt", "isPinned", "fromUniversalClipboard"]
        let inline = makeClip()
        let irec = record(for: inline)
        try SyncRecordMapper.populate(irec, from: inline, assetDirectory: dir)
        XCTAssertEqual(Set(irec.encryptedValues.allKeys()), common.union(["rawData"]))

        let big = makeClip(bytes: SyncRecordMapper.inlineLimit + 1)
        let arec = record(for: big)
        try SyncRecordMapper.populate(arec, from: big, assetDirectory: dir)
        XCTAssertEqual(Set(arec.encryptedValues.allKeys()), common.union(["assetKey"]))

        let board = PinboardSnapshot(id: UUID(), name: "n", displayOrder: 1, createdAt: Date())
        let brec = CKRecord(recordType: SyncRecordMapper.pinboardType, recordID: SyncRecordMapper.recordID(for: board.id))
        SyncRecordMapper.populate(brec, from: board)
        XCTAssertEqual(Set(brec.encryptedValues.allKeys()), ["name", "displayOrder", "createdAt"])

        let entry = EntrySnapshot(id: UUID(), clipID: UUID(), pinboardID: UUID(), displayOrder: 2, addedAt: Date())
        let erec = CKRecord(recordType: SyncRecordMapper.entryType, recordID: SyncRecordMapper.recordID(for: entry.id))
        SyncRecordMapper.populate(erec, from: entry)
        XCTAssertEqual(Set(erec.encryptedValues.allKeys()), ["displayOrder", "addedAt"])
    }

    func testEntryReferencesDeleteSelf() {
        let entry = EntrySnapshot(id: UUID(), clipID: UUID(), pinboardID: UUID(), displayOrder: 2, addedAt: Date())
        let rec = CKRecord(recordType: SyncRecordMapper.entryType, recordID: SyncRecordMapper.recordID(for: entry.id))
        SyncRecordMapper.populate(rec, from: entry)
        let clipRef = rec["clip"] as? CKRecord.Reference
        let boardRef = rec["pinboard"] as? CKRecord.Reference
        XCTAssertEqual(clipRef?.action, .deleteSelf)
        XCTAssertEqual(boardRef?.action, .deleteSelf)
        XCTAssertEqual(clipRef?.recordID.recordName, entry.clipID.uuidString)
        XCTAssertEqual(boardRef?.recordID.recordName, entry.pinboardID.uuidString)
    }

    func testPinboardRoundTrip() throws {
        let board = PinboardSnapshot(id: UUID(), name: "Work", displayOrder: 3,
                                     createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let rec = CKRecord(recordType: SyncRecordMapper.pinboardType, recordID: SyncRecordMapper.recordID(for: board.id))
        SyncRecordMapper.populate(rec, from: board)
        XCTAssertEqual(try SyncRecordMapper.pinboard(from: rec), board)
    }

    func testEntryRoundTrip() throws {
        let entry = EntrySnapshot(id: UUID(), clipID: UUID(), pinboardID: UUID(), displayOrder: 4,
                                  addedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let rec = CKRecord(recordType: SyncRecordMapper.entryType, recordID: SyncRecordMapper.recordID(for: entry.id))
        SyncRecordMapper.populate(rec, from: entry)
        XCTAssertEqual(try SyncRecordMapper.entry(from: rec), entry)
    }

    func testDecodeMissingFieldThrows() {
        let rec = CKRecord(recordType: SyncRecordMapper.clipType, recordID: SyncRecordMapper.recordID(for: UUID()))
        XCTAssertThrowsError(try SyncRecordMapper.clip(from: rec)) { error in
            guard case SyncRecordMapper.DecodeError.missingField = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testSwitchingToInlineClearsAsset() throws {
        var clip = makeClip(bytes: SyncRecordMapper.inlineLimit + 1)
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        clip.rawData = Data([1, 2, 3])
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        XCTAssertNil(rec["payload"])
        XCTAssertNil(rec.encryptedValues["assetKey"] as Data?)
        XCTAssertEqual(try SyncRecordMapper.clip(from: rec).rawData, clip.rawData)
    }

    func testLargeTextGoesToTextPayload() throws {
        var clip = makeClip()
        clip.textContent = String(repeating: "é", count: SyncRecordMapper.inlineLimit / 2 + 1)  // 2 UTF-8 bytes each
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        XCTAssertFalse(rec.encryptedValues.allKeys().contains("textContent"))
        XCTAssertNotNil(rec["textPayload"] as CKAsset?)
        XCTAssertNotNil(rec.encryptedValues["assetKey"] as Data?)
        XCTAssertNotNil(rec.encryptedValues["rawData"] as Data?)
        XCTAssertNil(rec["payload"])
        let sealed = try Data(contentsOf: SyncRecordMapper.textAssetURL(for: clip.id, in: dir))
        XCTAssertNil(sealed.range(of: Data(clip.textContent!.utf8.prefix(64))))
        XCTAssertEqual(try SyncRecordMapper.clip(from: rec), clip)
    }

    func testSwitchingFromLargeToSmallTextClearsTextPayload() throws {
        var clip = makeClip()
        clip.textContent = String(repeating: "a", count: SyncRecordMapper.inlineLimit + 1)
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        clip.textContent = "small"
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        XCTAssertNil(rec["textPayload"])
        XCTAssertNil(rec.encryptedValues["assetKey"] as Data?)
        XCTAssertEqual(rec.encryptedValues["textContent"] as String?, "small")
        XCTAssertEqual(try SyncRecordMapper.clip(from: rec), clip)
    }

    func testSwitchingToAssetClearsInlineData() throws {
        var clip = makeClip(bytes: 3)
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        clip.rawData = Data(count: SyncRecordMapper.inlineLimit + 1)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        XCTAssertNil(rec.encryptedValues["rawData"] as Data?)
        XCTAssertNotNil(rec["payload"] as CKAsset?)
        XCTAssertEqual(try SyncRecordMapper.clip(from: rec).rawData, clip.rawData)
    }

    // MARK: - Metadata changes leave the payload on the server

    /// What `CloudSyncEngine` builds a send from: the record rebuilt from its archived system fields, with no values.
    private func cached(_ rec: CKRecord) -> (record: CKRecord, serverContentHash: String?) {
        SyncRecordMapper.record(rec.recordType, rec.recordID, systemFields: SyncRecordMapper.archive(rec))
    }

    func testArchivedSystemFieldsKeepTheServersContentHash() throws {
        let clip = makeClip()
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        let (rebuilt, hash) = cached(rec)
        XCTAssertEqual(rebuilt.recordID, rec.recordID)
        XCTAssertEqual(hash, "hash")
        XCTAssertTrue(rebuilt.changedKeys().isEmpty, "only system fields come back")
    }

    func testNoArchiveMeansANewRecordAndNoHash() {
        let id = SyncRecordMapper.recordID(for: UUID())
        let (rebuilt, hash) = SyncRecordMapper.record(SyncRecordMapper.clipType, id, systemFields: nil)
        XCTAssertEqual(rebuilt.recordID, id)
        XCTAssertNil(hash)
        let board = CKRecord(recordType: SyncRecordMapper.pinboardType, recordID: id)
        XCTAssertNil(cached(board).serverContentHash, "pinboards and entries carry no content")
    }

    func testMetadataChangeSendsNoPayload() throws {
        var clip = makeClip(bytes: SyncRecordMapper.inlineLimit + 1)
        clip.textContent = String(repeating: "t", count: SyncRecordMapper.inlineLimit + 1)
        let first = record(for: clip)
        try SyncRecordMapper.populate(first, from: clip, assetDirectory: dir)
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        clip.isPinned.toggle()
        clip.userTitle = "renamed"
        let (rec, serverHash) = cached(first)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir, serverContentHash: serverHash)

        let sent = Set(rec.changedKeys()).union(rec.encryptedValues.changedKeys())
        XCTAssertTrue(sent.isDisjoint(with: ["payload", "textPayload", "assetKey", "rawData", "textContent", "fileManifest"]),
                      "untouched keys keep their server values: \(sent)")
        XCTAssertEqual(rec.encryptedValues["isPinned"] as Int64?, clip.isPinned ? 1 : 0)
        XCTAssertEqual(rec.encryptedValues["userTitle"] as String?, "renamed")
        XCTAssertEqual(rec.encryptedValues["contentHash"] as String?, "hash")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty, "nothing sealed")
    }

    func testChangedContentSendsThePayload() throws {
        var clip = makeClip(bytes: SyncRecordMapper.inlineLimit + 1)
        let first = record(for: clip)
        try SyncRecordMapper.populate(first, from: clip, assetDirectory: dir)
        clip.rawData = Data(count: SyncRecordMapper.inlineLimit + 2)
        clip.contentHash = "other"
        let (rec, serverHash) = cached(first)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir, serverContentHash: serverHash)
        XCTAssertNotNil(rec["payload"] as CKAsset?)
        XCTAssertNotNil(rec.encryptedValues["assetKey"] as Data?)
    }
}
