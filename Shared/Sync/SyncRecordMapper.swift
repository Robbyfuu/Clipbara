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
    /// A `.files` clip's manifest JSON (`FileBundle.manifestJSON`); nil for every other clip.
    var fileManifest: Data? = nil
    /// `ClipboardItem.fromUniversalClipboard`.
    var fromUniversalClipboard: Bool = false
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

struct AppIdentitySnapshot: Equatable, Sendable {
    var bundleId: String
    var name: String
    var iconPNG: Data
    var colorHex: String
    var updatedAt: Date

    var id: UUID { AppIdentity.id(for: bundleId) }
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
    static let appIdentityType = "AppIdentity"
    static let inlineLimit = 262_144
    static let maxClipBytes = 20_971_520

    enum DecodeError: Error {
        case missingField(String)
        /// An `AppIdentity` record not named after its own bundle id.
        case recordNameMismatch
    }

    /// A fetched record, decoded by its type.
    enum Fetched: Equatable {
        case clip(ClipSnapshot), pinboard(PinboardSnapshot), entry(EntrySnapshot), appIdentity(AppIdentitySnapshot)
    }

    static func recordID(for id: UUID) -> CKRecord.ID {
        recordID(named: id.uuidString)
    }

    static func recordID(for identity: AppIdentitySnapshot) -> CKRecord.ID {
        recordID(named: AppIdentity.recordName(for: identity.bundleId))
    }

    /// In the default zone: a server record ID can carry the real owner name instead of the default one.
    static func recordID(named name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    /// The local id behind a record name: the UUID of a clip, pinboard or entry, or an app identity's id (the first
    /// 16 bytes of the hash in its `app-` name). Nil for any other name.
    static func localID(_ recordName: String) -> UUID? {
        if let id = UUID(uuidString: recordName) { return id }
        guard recordName.hasPrefix("app-") else { return nil }
        let h = Array(recordName.dropFirst(4).prefix(32))
        guard h.count == 32 else { return nil }
        return UUID(uuidString: [h[0..<8], h[8..<12], h[12..<16], h[16..<20], h[20..<32]].map { String($0) }.joined(separator: "-"))
    }

    /// `fileURL` clips hold a local path and never sync. A `files` bundle may hold up to `FileBundle.maxFiles`
    /// files of `FileBundle.maxFileBytes` each, so it gets its own cap. A secret (`isSensitive`) never syncs: the
    /// batch builder asks here last, so nothing queued by any path uploads one.
    static func isEligible(contentType: String, byteCount: Int, isSensitive: Bool) -> Bool {
        if isSensitive { return false }
        return switch contentType {
        case ContentType.fileURL.rawValue: false
        case ContentType.files.rawValue: byteCount <= FileBundle.maxBundleBytes
        default: byteCount <= maxClipBytes
        }
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
    ///
    /// `serverContentHash` is the `contentHash` of what the server record already holds (`record(_:_:systemFields:)`).
    /// When it matches, a pin, rename or merge sends only the metadata: content keys never set on a record rebuilt from
    /// system fields keep their server values, so a file clip's 49 MB payload and its `assetKey` stay as they are.
    static func populate(_ record: CKRecord, from clip: ClipSnapshot, assetDirectory: URL,
                         serverContentHash: String? = nil) throws {
        let values = record.encryptedValues
        values["contentType"] = clip.contentType
        values["userTitle"] = clip.userTitle
        values["sourceAppName"] = clip.sourceAppName
        values["sourceAppBundleId"] = clip.sourceAppBundleId
        values["contentHash"] = clip.contentHash
        values["copiedAt"] = clip.copiedAt
        values["isPinned"] = Int64(clip.isPinned ? 1 : 0)
        values["fromUniversalClipboard"] = Int64(clip.fromUniversalClipboard ? 1 : 0)
        guard serverContentHash != clip.contentHash else { return }

        // Names, sizes and types of a file clip, readable without opening the payload. Nil for other clips.
        values["fileManifest"] = clip.contentType == ContentType.files.rawValue ? FileBundle.manifestJSON(clip.rawData) : nil

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

    /// The icon goes inline (encrypted): a 128 px PNG is far under `inlineLimit`.
    static func populate(_ record: CKRecord, from identity: AppIdentitySnapshot) {
        let values = record.encryptedValues
        values["bundleId"] = identity.bundleId
        values["name"] = identity.name
        values["iconPNG"] = identity.iconPNG
        values["colorHex"] = identity.colorHex
        values["updatedAt"] = identity.updatedAt
    }

    // MARK: - System fields

    /// Stored next to the system fields: the `contentHash` of the content the server record holds.
    private static let serverContentHashKey = "CopydServerContentHash"

    /// A record's system fields, plus the `contentHash` it carries (a sent, fetched or conflicting server record).
    static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.encode(record.encryptedValues["contentHash"] as String?, forKey: serverContentHashKey)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// A record carrying the archived system fields (avoids false conflicts) and the hash of the content the server
    /// holds, or a new record and nil. Archives written before the hash was kept give nil: the next send uploads it all.
    static func record(_ type: CKRecord.RecordType, _ id: CKRecord.ID,
                       systemFields: Data?) -> (record: CKRecord, serverContentHash: String?) {
        if let systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            coder.requiresSecureCoding = true
            let cached = CKRecord(coder: coder)
            let hash = coder.decodeObject(of: NSString.self, forKey: serverContentHashKey) as String?
            coder.finishDecoding()
            // Type only: a cached recordID can carry the real owner name instead of the default one.
            if let cached, cached.recordType == type { return (cached, hash) }
        }
        return (CKRecord(recordType: type, recordID: id), nil)
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
            isPinned: pinned != 0,
            fileManifest: values["fileManifest"] as? Data,
            // Records saved before this field existed have none: an ordinary copy.
            fromUniversalClipboard: (values["fromUniversalClipboard"] as? Int64 ?? 0) != 0)
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

    /// Throws for a record not named after its own bundle id: its system fields would land on another app's identity.
    static func appIdentity(from record: CKRecord) throws -> AppIdentitySnapshot {
        let bundleId: String = try required(record, "bundleId")
        guard record.recordID.recordName == AppIdentity.recordName(for: bundleId) else {
            throw DecodeError.recordNameMismatch
        }
        return AppIdentitySnapshot(
            bundleId: bundleId, name: try required(record, "name"), iconPNG: try required(record, "iconPNG"),
            colorHex: try required(record, "colorHex"), updatedAt: try required(record, "updatedAt"))
    }

    /// Nil for a record type this version doesn't know: the engine skips it, as older versions skip `AppIdentity`.
    static func decode(_ record: CKRecord) throws -> Fetched? {
        switch record.recordType {
        case clipType: .clip(try clip(from: record))
        case pinboardType: .pinboard(try pinboard(from: record))
        case entryType: .entry(try entry(from: record))
        case appIdentityType: .appIdentity(try appIdentity(from: record))
        default: nil
        }
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
