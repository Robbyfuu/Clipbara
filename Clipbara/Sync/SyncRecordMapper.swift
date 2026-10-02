import CloudKit
import Foundation

struct ClipSnapshot: Equatable, Sendable {
    var id: UUID
    var contentType: String
    var rawData: Data
    var textContent: String?
    var userTitle: String?
    var sourceAppName: String?
    var sourceAppBundleId: String?
    var contentHash: String
    var copiedAt: Date
    var isPinned: Bool
}

struct PinboardSnapshot: Equatable, Sendable {
    var id: UUID
    var name: String
    var displayOrder: Int
    var createdAt: Date
}

struct EntrySnapshot: Equatable, Sendable {
    var id: UUID
    var clipID: UUID
    var pinboardID: UUID
    var displayOrder: Int
    var addedAt: Date
}

/// Converts value snapshots to and from CKRecords. Every content field is stored in
/// `encryptedValues`; only the entry references and the (already sealed) asset are plain.
enum SyncRecordMapper {
    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "Clipboard", ownerName: CKCurrentUserDefaultName)
    }

    static let clipType = "Clip"
    static let pinboardType = "Pinboard"
    static let entryType = "PinboardEntry"
    static let inlineLimit = 262_144
    static let maxClipBytes = 20_971_520

    enum DecodeError: Error { case missingField(String) }

    static func recordID(for id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: zoneID)
    }

    static func isEligible(contentType: String, byteCount: Int) -> Bool {
        contentType != "fileURL" && byteCount <= maxClipBytes
    }

    static func assetURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).bin")
    }

    // MARK: - Populate

    static func populate(_ record: CKRecord, from clip: ClipSnapshot, assetDirectory: URL) throws {
        let values = record.encryptedValues
        values["contentType"] = clip.contentType
        values["textContent"] = clip.textContent
        values["userTitle"] = clip.userTitle
        values["sourceAppName"] = clip.sourceAppName
        values["sourceAppBundleId"] = clip.sourceAppBundleId
        values["contentHash"] = clip.contentHash
        values["copiedAt"] = clip.copiedAt
        values["isPinned"] = Int64(clip.isPinned ? 1 : 0)

        if clip.rawData.count <= inlineLimit {
            values["rawData"] = clip.rawData
            values["assetKey"] = nil as Data?
            record["payload"] = nil
        } else {
            let key = AssetCrypto.makeKey()
            let url = assetURL(for: clip.id, in: assetDirectory)
            try AssetCrypto.seal(clip.rawData, key: key).write(to: url, options: .atomic)
            values["rawData"] = nil as Data?
            values["assetKey"] = key
            record["payload"] = CKAsset(fileURL: url)
        }
    }

    static func populate(_ record: CKRecord, from board: PinboardSnapshot) {
        let values = record.encryptedValues
        values["name"] = board.name
        values["displayOrder"] = Int64(board.displayOrder)
        values["createdAt"] = board.createdAt
    }

    static func populate(_ record: CKRecord, from entry: EntrySnapshot) {
        record["clip"] = CKRecord.Reference(recordID: recordID(for: entry.clipID), action: .deleteSelf)
        record["pinboard"] = CKRecord.Reference(recordID: recordID(for: entry.pinboardID), action: .deleteSelf)
        record.encryptedValues["displayOrder"] = Int64(entry.displayOrder)
        record.encryptedValues["addedAt"] = entry.addedAt
    }

    // MARK: - Decode

    private static func required<T: CKRecordValueProtocol>(_ record: CKRecord, _ key: String) throws -> T {
        guard let value = record.encryptedValues[key] as? T else { throw DecodeError.missingField(key) }
        return value
    }

    private static func id(of record: CKRecord) throws -> UUID {
        guard let id = UUID(uuidString: record.recordID.recordName) else {
            throw DecodeError.missingField("recordName")
        }
        return id
    }

    static func clip(from record: CKRecord) throws -> ClipSnapshot {
        let values = record.encryptedValues
        let rawData: Data
        if let inline = values["rawData"] as? Data {
            rawData = inline
        } else if let asset = record["payload"] as? CKAsset {
            guard let url = asset.fileURL else { throw DecodeError.missingField("payload.fileURL") }
            guard let key = values["assetKey"] as? Data else { throw DecodeError.missingField("assetKey") }
            rawData = try AssetCrypto.open(Data(contentsOf: url), key: key)
        } else {
            throw DecodeError.missingField("rawData")
        }
        let pinned: Int64 = try required(record, "isPinned")
        return ClipSnapshot(
            id: try id(of: record),
            contentType: try required(record, "contentType"),
            rawData: rawData,
            textContent: values["textContent"] as? String,
            userTitle: values["userTitle"] as? String,
            sourceAppName: values["sourceAppName"] as? String,
            sourceAppBundleId: values["sourceAppBundleId"] as? String,
            contentHash: try required(record, "contentHash"),
            copiedAt: try required(record, "copiedAt"),
            isPinned: pinned != 0)
    }

    static func pinboard(from record: CKRecord) throws -> PinboardSnapshot {
        let order: Int64 = try required(record, "displayOrder")
        return PinboardSnapshot(
            id: try id(of: record), name: try required(record, "name"),
            displayOrder: Int(order), createdAt: try required(record, "createdAt"))
    }

    static func entry(from record: CKRecord) throws -> EntrySnapshot {
        guard let clipRef = record["clip"] as? CKRecord.Reference,
              let clipID = UUID(uuidString: clipRef.recordID.recordName) else {
            throw DecodeError.missingField("clip")
        }
        guard let boardRef = record["pinboard"] as? CKRecord.Reference,
              let boardID = UUID(uuidString: boardRef.recordID.recordName) else {
            throw DecodeError.missingField("pinboard")
        }
        let order: Int64 = try required(record, "displayOrder")
        return EntrySnapshot(
            id: try id(of: record), clipID: clipID, pinboardID: boardID,
            displayOrder: Int(order), addedAt: try required(record, "addedAt"))
    }
}
