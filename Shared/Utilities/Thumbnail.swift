import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Thumbnail {
    #if os(macOS)
    /// Retina pixels, as the Mac produced before the ImageIO rewrite.
    private static let pixelScale: CGFloat = 2
    #else
    /// 1x pixels keep the keyboard extension inside its memory budget.
    private static let pixelScale: CGFloat = 1
    #endif

    /// The thumbnail a clip shows: the image itself, or a file clip's first image file. Nil for anything else.
    static func png(for type: ContentType, rawData: Data) -> Data? {
        switch type {
        case .image: png(from: rawData)
        case .files: (try? FileBundle.decode(rawData))?.first { UTType($0.uti)?.conforms(to: .image) == true }
            .flatMap { png(from: $0.data) }
        default: nil
        }
    }

    /// PNG thumbnail whose point size fits `maxSize` on the longest side. Never upscales.
    /// The Mac renders twice the pixels and stamps a DPI that keeps the point size unchanged.
    static func png(from data: Data, maxSize: CGFloat = 320) -> Data? {
        guard let image = image(from: data, maxPixels: maxSize * pixelScale) else { return nil }
        // 144 dpi for a full Retina thumbnail, 72 when the source was already smaller than `maxSize`.
        let dpi = 72 * max(1, CGFloat(max(image.width, image.height)) / maxSize)
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// A tiny JPEG for a payload with a hard size cap (the Live Activity's 4 KB). `maxPixels` on the longest side.
    // ponytail: JPEG has no alpha, so transparent pixels turn black; HEIC keeps alpha if that ever shows.
    static func jpeg(from data: Data, maxPixels: CGFloat, quality: CGFloat) -> Data? {
        guard let image = image(from: data, maxPixels: maxPixels) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func image(from data: Data, maxPixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
