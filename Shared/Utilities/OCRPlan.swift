import CoreGraphics
import Foundation

/// The pure parts of reading text in image clips: which clips go next, and how far an image is downsampled first.
/// Vision itself lives in `ImageTextRecognizer`, which only the apps compile.
enum OCRPlan {
    /// The longest side, in pixels, Vision gets. A giant screenshot is never decoded at full size.
    static let targetPixelSize: CGFloat = 2048
    /// The fill pass looks at this many of the newest image clips, `batchSize` at a time.
    static let window = 300
    static let batchSize = 10

    /// The newest image clips not read yet, at most `limit`, among the `window` newest image clips.
    static func nextBatch(clips: [(id: UUID, isImage: Bool, ocrDone: Bool, copiedAt: Date)],
                          limit: Int = batchSize, window: Int = window) -> [UUID] {
        clips.filter(\.isImage).sorted { $0.copiedAt > $1.copiedAt }.prefix(window)
            .filter { !$0.ocrDone }.prefix(limit).map(\.id)
    }

    /// The image Vision reads: at most `targetPixelSize` on its longest side, decoded by ImageIO at that size.
    static func downsampled(_ data: Data) -> CGImage? {
        Thumbnail.image(from: data, maxPixels: targetPixelSize)
    }
}

extension ClipboardItem {
    /// An image's recognized text, for "Copy text", the "Aa" badge and Quick Look. Nil until read, or with none.
    var recognizedText: String? {
        guard contentType == .image, let ocrText, !ocrText.isEmpty else { return nil }
        return ocrText
    }
}
