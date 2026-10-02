import Foundation
import SwiftData

extension ClipboardItem {
    var snapshot: ClipSnapshot {
        ClipSnapshot(
            id: id, contentType: contentTypeRaw, rawData: rawData, textContent: textContent,
            userTitle: userTitle, sourceAppName: sourceAppName, sourceAppBundleId: sourceAppBundleId,
            contentHash: contentHash, copiedAt: copiedAt, isPinned: isPinned)
    }

    /// Copies every field except `id`, `thumbnailData` and `syncSystemFields`.
    func update(from s: ClipSnapshot) {
        contentTypeRaw = s.contentType
        rawData = s.rawData
        textContent = s.textContent
        userTitle = s.userTitle
        sourceAppName = s.sourceAppName
        sourceAppBundleId = s.sourceAppBundleId
        contentHash = s.contentHash
        copiedAt = s.copiedAt
        isPinned = s.isPinned
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
