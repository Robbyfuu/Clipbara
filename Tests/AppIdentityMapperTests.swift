import CloudKit
import XCTest

final class AppIdentityMapperTests: XCTestCase {
    private let snapshot = AppIdentitySnapshot(
        bundleId: "com.apple.Safari", name: "Safari", iconPNG: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]),
        colorHex: "#1E90FF", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

    private func record(_ s: AppIdentitySnapshot) -> CKRecord {
        CKRecord(recordType: SyncRecordMapper.appIdentityType, recordID: SyncRecordMapper.recordID(for: s))
    }

    func testRecordIDIsTheStableNameInTheClipboardZone() {
        let rid = SyncRecordMapper.recordID(for: snapshot)
        XCTAssertEqual(rid.recordName, AppIdentity.recordName(for: "com.apple.Safari"))
        XCTAssertEqual(rid.zoneID.zoneName, "Clipboard")
        XCTAssertEqual(SyncRecordMapper.appIdentityType, "AppIdentity")
    }

    func testRoundTrip() throws {
        let rec = record(snapshot)
        SyncRecordMapper.populate(rec, from: snapshot)
        XCTAssertEqual(try SyncRecordMapper.appIdentity(from: rec), snapshot)
    }

    /// Every field is end-to-end encrypted, the icon included: nothing readable sits in the plain fields.
    func testEveryFieldIsEncrypted() {
        let rec = record(snapshot)
        SyncRecordMapper.populate(rec, from: snapshot)
        // allKeys() lists encrypted keys too (as SyncRecordMapperTests.plainKeys does).
        XCTAssertEqual(Set(rec.allKeys()).subtracting(rec.encryptedValues.allKeys()), [])
        XCTAssertEqual(Set(rec.encryptedValues.allKeys()), ["bundleId", "name", "iconPNG", "colorHex", "updatedAt"])
        XCTAssertEqual(rec.encryptedValues["bundleId"] as String?, "com.apple.Safari")
        XCTAssertEqual(rec.encryptedValues["iconPNG"] as Data?, snapshot.iconPNG)
    }

    /// A record whose name is not its bundle id's would store its system fields on another app's identity.
    func testRejectsARecordNamedForAnotherApp() {
        let other = AppIdentitySnapshot(bundleId: "com.apple.Notes", name: "Notes", iconPNG: Data([1]),
                                        colorHex: "#FFCC00", updatedAt: snapshot.updatedAt)
        let rec = record(snapshot)
        SyncRecordMapper.populate(rec, from: other)
        XCTAssertThrowsError(try SyncRecordMapper.appIdentity(from: rec)) { error in
            guard case SyncRecordMapper.DecodeError.recordNameMismatch = error else { return XCTFail("\(error)") }
        }
    }

    func testDecodeDispatchesEveryKnownType() throws {
        let rec = record(snapshot)
        SyncRecordMapper.populate(rec, from: snapshot)
        XCTAssertEqual(try SyncRecordMapper.decode(rec), .appIdentity(snapshot))

        let board = PinboardSnapshot(id: UUID(), name: "Work", displayOrder: 1, createdAt: snapshot.updatedAt)
        let boardRecord = CKRecord(recordType: SyncRecordMapper.pinboardType, recordID: SyncRecordMapper.recordID(for: board.id))
        SyncRecordMapper.populate(boardRecord, from: board)
        XCTAssertEqual(try SyncRecordMapper.decode(boardRecord), .pinboard(board))
    }

    /// The engine's switch skips a type it does not know, as every older client skips `AppIdentity`: a newer type
    /// decodes to nil, never to an error that would stop the fetch.
    func testUnknownRecordTypeStillSkippedByOlderLogic() throws {
        let rec = CKRecord(recordType: "SmartBoard", recordID: SyncRecordMapper.recordID(for: UUID()))
        rec.encryptedValues["name"] = "Code"
        XCTAssertNil(try SyncRecordMapper.decode(rec))
    }
}
