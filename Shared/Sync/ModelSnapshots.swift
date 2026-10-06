import Foundation
import SwiftData

extension ClipboardItem {
    var snapshot: ClipSnapshot {
        ClipSnapshot(
            id: id, contentType: contentTypeRaw, rawData: rawData, textContent: textContent,
            userTitle: userTitle, sourceAppName: sourceAppName, sourceAppBundleId: sourceAppBundleId,
            contentHash: contentHash, copiedAt: copiedAt, isPinned: isPinned, fileManifest: fileManifestData,
            fromUniversalClipboard: fromUniversalClipboard)
    }

    /// Copies every field except `id`, `thumbnailData`, `syncSystemFields` and the local-only ones. `rawData` is written
    /// only when it differs, so an echo of our own save does not rewrite the external blob. Returns whether it did.
    /// New content drops the text read in the old image, so the fill pass reads it again.
    @discardableResult
    func update(from s: ClipSnapshot) -> Bool {
        let rawChanged = rawData != s.rawData
        if rawChanged {
            rawData = s.rawData
            ocrText = nil
            ocrDone = false
            // An edit on another device: the old link's preview goes, and the new link is fetched here.
            linkTitle = nil
            linkImageData = nil
            linkPreviewDone = false
            // And it is sorted into the automatic pinboards again, and asked about its topic.
            smartKinds = 0
            smartKindsVersion = 0
            topicRaw = nil
            topicDone = false
        }
        fileManifestData = s.fileManifest
        contentTypeRaw = s.contentType
        textContent = s.textContent
        userTitle = s.userTitle
        sourceAppName = s.sourceAppName
        sourceAppBundleId = s.sourceAppBundleId
        contentHash = s.contentHash
        copiedAt = s.copiedAt
        isPinned = s.isPinned
        fromUniversalClipboard = s.fromUniversalClipboard
        return rawChanged
    }

    var isSyncEligible: Bool {
        SyncRecordMapper.isEligible(contentType: contentTypeRaw, byteCount: rawData.count, isSensitive: isSensitive)
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

extension AppIdentity {
    var snapshot: AppIdentitySnapshot {
        AppIdentitySnapshot(bundleId: bundleId, name: name, iconPNG: iconPNG, colorHex: colorHex, updatedAt: updatedAt)
    }

    /// Every synced field; `id` follows from `bundleId`, which never changes for one record.
    func update(from s: AppIdentitySnapshot) {
        name = s.name
        iconPNG = s.iconPNG
        colorHex = s.colorHex
        updatedAt = s.updatedAt
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

    func syncIdentity(id: UUID) -> AppIdentity? {
        var d = FetchDescriptor<AppIdentity>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try? fetch(d).first
    }
}
