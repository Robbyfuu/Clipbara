import Foundation
import SwiftData

@Model
final class ClipboardItem {

    var id: UUID
    var contentTypeRaw: String
    @Attribute(.externalStorage) var rawData: Data
    var textContent: String?
    @Attribute(.externalStorage) var thumbnailData: Data?
    var sourceAppName: String?
    var sourceAppBundleId: String?
    var contentHash: String
    var copiedAt: Date
    var userTitle: String?
    var isPinned: Bool
    var syncSystemFields: Data?
    /// A `.files` clip's names and sizes (`FileBundle.manifestJSON`), so cards never read `rawData`. Nil otherwise.
    var fileManifestData: Data?
    /// The Mac captured this copy from Universal Clipboard: it was made on another device, usually this user's iPhone.
    /// The iPhone never announces it. Additive with a default, so existing stores migrate lightweight.
    var fromUniversalClipboard: Bool = false
    /// The capture matched `SecretDetector`. Local only: never synced, masked in every view, deleted by `SecretSweeper`.
    /// Additive with a default, so existing stores migrate lightweight.
    var isSensitive: Bool = false
    /// The text Vision read in an image clip (`ImageTextQueue`). Local only: never synced, each device reads its own.
    /// Never sent to the suggestions model. Additive, so existing stores migrate lightweight.
    var ocrText: String?
    /// Recognition already ran, so an image with no text is never read again. Local only, like `ocrText`.
    var ocrDone: Bool = false

    var contentType: ContentType {
        get { ContentType(rawValue: contentTypeRaw) ?? .unknown }
        set { contentTypeRaw = newValue.rawValue }
    }

    /// Deleted, by the secret sweep, a remote delete or the user, while a view or key handler still holds it.
    /// Reading its attributes then traps.
    var isGone: Bool { isDeleted || modelContext == nil }

    var fileManifest: [FileManifestEntry]? {
        fileManifestData.flatMap { try? JSONDecoder().decode([FileManifestEntry].self, from: $0) }
    }

    init(
        contentType: ContentType,
        rawData: Data,
        textContent: String? = nil,
        thumbnailData: Data? = nil,
        sourceAppName: String? = nil,
        sourceAppBundleId: String? = nil,
        contentHash: String
    ) {
        self.id = UUID()
        self.contentTypeRaw = contentType.rawValue
        self.rawData = rawData
        self.textContent = textContent
        self.thumbnailData = thumbnailData
        self.sourceAppName = sourceAppName
        self.sourceAppBundleId = sourceAppBundleId
        self.contentHash = contentHash
        self.copiedAt = Date()
        self.isPinned = false
    }
}
