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
    /// A link clip's page title, fetched by `LinkPreviewQueue`. Local only, like `ocrText`: each device fetches its own.
    /// Additive, so existing stores migrate lightweight.
    var linkTitle: String?
    /// The page's image (or icon), a JPEG at most `LinkPreviewPlan.targetPixelSize` wide. Local only.
    @Attribute(.externalStorage) var linkImageData: Data?
    /// The fetch finished, with a preview or none, so a dead link is never fetched again. Local only.
    var linkPreviewDone: Bool = false
    /// The type boards the clip shows in (`SmartBoard.bit`), sorted by `SmartKindsQueue`. Local only, like `ocrText`:
    /// each device sorts its own. Additive, so existing stores migrate lightweight.
    var smartKinds: Int = 0
    /// The `SmartKinds.version` that sorted `smartKinds`; 0 until sorted. Local only.
    var smartKindsVersion: Int = 0
    /// The topic board (`SmartBoard.rawValue`) Apple Intelligence put the clip in, by `TopicQueue`; nil for none.
    /// Local only, like `smartKinds`: each device asks its own model. Additive, so existing stores migrate lightweight.
    var topicRaw: String?
    /// The model answered, with a topic or none, so the clip is never asked again. Local only.
    var topicDone: Bool = false

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

    /// One clip's data, read in a context of its own, so off the main actor: "Paste as" and "Copy as → Markdown". Empty
    /// when the clip is gone.
    nonisolated static func rawData(of id: UUID, in container: ModelContainer) -> Data {
        var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 1
        return (try? ModelContext(container).fetch(fetch).first?.rawData) ?? Data()
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
