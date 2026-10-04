import Foundation
import SwiftData

extension ClipboardItem {
    var snapshot: ClipSnapshot {
        ClipSnapshot(
            id: id, contentType: contentTypeRaw, rawData: rawData, textContent: textContent,
            userTitle: userTitle, sourceAppName: sourceAppName, sourceAppBundleId: sourceAppBundleId,
            contentHash: contentHash, copiedAt: copiedAt, isPinned: isPinned, fileManifest: fileManifestData)
    }

    /// Copies every field except `id`, `thumbnailData` and `syncSystemFields`. `rawData` is written only
    /// when it differs, so an echo of our own save does not rewrite the external blob. Returns whether it did.
    @discardableResult
    func update(from s: ClipSnapshot) -> Bool {
        let rawChanged = rawData != s.rawData
        if rawChanged { rawData = s.rawData }
        fileManifestData = s.fileManifest
        contentTypeRaw = s.contentType
        textContent = s.textContent
        userTitle = s.userTitle
        sourceAppName = s.sourceAppName
        sourceAppBundleId = s.sourceAppBundleId
        contentHash = s.contentHash
        copiedAt = s.copiedAt
        isPinned = s.isPinned
        return rawChanged
    }

    var isSyncEligible: Bool {
        SyncRecordMapper.isEligible(contentType: contentTypeRaw, byteCount: rawData.count)
    }
}

extension Pinboard {
    var snapshot: PinboardSnapshot {
        PinboardSnapshot(id: id, name: name, displayOrder: displayOrder, createdAt: createdAt)
    }

    func update(from s: PinboardSnapshot) {
        name = s.name
        displayOrder = s.displayOrder
        createdAt = s.createdAt
    }
}

extension PinboardEntry {
    var snapshot: EntrySnapshot? {
        guard let clip = clipboardItem, let board = pinboard else { return nil }
        return EntrySnapshot(id: id, clipID: clip.id, pinboardID: board.id, displayOrder: displayOrder, addedAt: addedAt)
    }
}

extension ModelContext {
    func syncClip(id: UUID) -> ClipboardItem? {
        var d = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? fetch(d).first
    }

    func syncPinboard(id: UUID) -> Pinboard? {
        var d = FetchDescriptor<Pinboard>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? fetch(d).first
    }

    func syncEntry(id: UUID) -> PinboardEntry? {
        var d = FetchDescriptor<PinboardEntry>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? fetch(d).first
    }
}
