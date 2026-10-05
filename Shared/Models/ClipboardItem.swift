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

    var contentType: ContentType {
        get { ContentType(rawValue: contentTypeRaw) ?? .unknown }
        set { contentTypeRaw = newValue.rawValue }
    }

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
