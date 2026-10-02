import CloudKit
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
            contentHash: "hash", copiedAt: Date(timeIntervalSince1970: 1_700_000_000), isPinned: full)
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
        XCTAssertFalse(SyncRecordMapper.isEligible(contentType: "fileURL", byteCount: 1))
        XCTAssertTrue(SyncRecordMapper.isEligible(contentType: "image", byteCount: 20_971_520))
        XCTAssertFalse(SyncRecordMapper.isEligible(contentType: "image", byteCount: 20_971_521))
    }

    func testOnlyAllowedPlainKeys() throws {
        let clip = makeClip(bytes: SyncRecordMapper.inlineLimit + 1)
        let rec = record(for: clip)
        try SyncRecordMapper.populate(rec, from: clip, assetDirectory: dir)
        XCTAssertTrue(plainKeys(rec).isSubset(of: ["payload"]))

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
                                   "sourceAppBundleId", "contentHash", "copiedAt", "isPinned"]
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
}
