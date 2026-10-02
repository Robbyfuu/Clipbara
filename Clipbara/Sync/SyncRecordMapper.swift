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

    static func textAssetURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).text.bin")
    }

    // MARK: - Populate

    /// `rawData` and `textContent` above `inlineLimit` each move to their own sealed asset,
    /// both under one `assetKey`, so every record stays under CloudKit's 1 MB limit.
    static func populate(_ record: CKRecord, from clip: ClipSnapshot, assetDirectory: URL) throws {
        let values = record.encryptedValues
        values["contentType"] = clip.contentType
        values["userTitle"] = clip.userTitle
        values["sourceAppName"] = clip.sourceAppName
        values["sourceAppBundleId"] = clip.sourceAppBundleId
        values["contentHash"] = clip.contentHash
        values["copiedAt"] = clip.copiedAt
        values["isPinned"] = Int64(clip.isPinned ? 1 : 0)

        let text = clip.textContent.map { Data($0.utf8) }
        let largeText = (text?.count ?? 0) > inlineLimit
        let largeRaw = clip.rawData.count > inlineLimit
        let key = largeText || largeRaw ? AssetCrypto.makeKey() : nil
        values["assetKey"] = key

        if largeRaw, let key {
            let url = assetURL(for: clip.id, in: assetDirectory)
            try AssetCrypto.seal(clip.rawData, key: key).write(to: url, options: .atomic)
            values["rawData"] = nil as Data?
            record["payload"] = CKAsset(fileURL: url)
        } else {
            values["rawData"] = clip.rawData
            record["payload"] = nil
        }

        if largeText, let text, let key {
            let url = textAssetURL(for: clip.id, in: assetDirectory)
            try AssetCrypto.seal(text, key: key).write(to: url, options: .atomic)
            values["textContent"] = nil as String?
            record["textPayload"] = CKAsset(fileURL: url)
        } else {
            values["textContent"] = clip.textContent
            record["textPayload"] = nil
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

    /// Opens the sealed asset in `field`, or nil when the record has none.
    private static func sealedAsset(_ record: CKRecord, _ field: String) throws -> Data? {
        guard let asset = record[field] as? CKAsset else { return nil }
        guard let url = asset.fileURL else { throw DecodeError.missingField("\(field).fileURL") }
        guard let key = record.encryptedValues["assetKey"] as? Data else { throw DecodeError.missingField("assetKey") }
        return try AssetCrypto.open(Data(contentsOf: url), key: key)
    }

    static func clip(from record: CKRecord) throws -> ClipSnapshot {
        let values = record.encryptedValues
        guard let rawData = try values["rawData"] as? Data ?? sealedAsset(record, "payload") else {
            throw DecodeError.missingField("rawData")
        }
        let textContent = try values["textContent"] as? String
            ?? sealedAsset(record, "textPayload").map { String(decoding: $0, as: UTF8.self) }
        let pinned: Int64 = try required(record, "isPinned")
        return ClipSnapshot(
            id: try id(of: record),
            contentType: try required(record, "contentType"),
            rawData: rawData,
            textContent: textContent,
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

extension Error {
    /// Domain, code and message only, safe for public logs: full error dumps can embed record or model values.
    var syncLogDescription: String {
        if let e = self as? SyncRecordMapper.DecodeError { return String(describing: e) }
        let e = self as NSError
        return "\(e.domain) \(e.code): \(e.localizedDescription)"
    }
}
