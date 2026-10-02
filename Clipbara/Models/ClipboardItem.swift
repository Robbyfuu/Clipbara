import Foundation
import AppKit
import SwiftData
import UniformTypeIdentifiers

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

    var contentType: ContentType {
        get { ContentType(rawValue: contentTypeRaw) ?? .unknown }
        set { contentTypeRaw = newValue.rawValue }
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

    func dragProvider() -> NSItemProvider {
        let provider: NSItemProvider

        switch contentType {
        case .plainText, .richText, .html, .unknown:
            provider = NSItemProvider(object: (textContent ?? "") as NSString)

        case .image:
            if let image = NSImage(data: rawData),
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Clipbara", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let asciiOnly = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_")
                let safeName = sourceAppName?
                    .unicodeScalars.filter { asciiOnly.contains($0) }
                    .reduce(into: "") { $0.append(String($1)) }
                    .trimmingCharacters(in: .whitespaces)
                let appName = (safeName?.isEmpty ?? true) ? "Clipbara" : safeName!
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                let filename = "\(appName) \(formatter.string(from: copiedAt)).png"
                let fileURL = dir.appendingPathComponent(filename)
                try? pngData.write(to: fileURL)
                provider = NSItemProvider(contentsOf: fileURL) ?? NSItemProvider(object: image)
            } else {
                provider = NSItemProvider()
            }

        case .url:
            if let text = textContent, let url = URL(string: text) {
                provider = NSItemProvider(object: url as NSURL)
            } else {
                provider = NSItemProvider(object: (textContent ?? "") as NSString)
            }

        case .fileURL:
            if let text = textContent, let url = URL(string: text) {
                provider = NSItemProvider(object: url as NSURL)
            } else {
                provider = NSItemProvider()
            }

        case .color:
            provider = NSItemProvider(object: (textContent ?? "") as NSString)
        }

        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.pasteClipClipboardItemID.identifier,
            visibility: .ownProcess
        ) { [id] completion in
            completion(id.uuidString.data(using: .utf8), nil)
            return nil
        }

        return provider
    }
}

extension UTType {
    static let pasteClipClipboardItemID = UTType(exportedAs: "com.minsang.PasteClip.clipboard-item-id")
}
