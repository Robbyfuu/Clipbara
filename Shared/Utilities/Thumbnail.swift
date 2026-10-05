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

    /// PNG thumbnail whose point size fits `maxSize` on the longest side. Never upscales.
    /// The Mac renders twice the pixels and stamps a DPI that keeps the point size unchanged.
    static func png(from data: Data, maxSize: CGFloat = 320) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize * pixelScale,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // 144 dpi for a full Retina thumbnail, 72 when the source was already smaller than `maxSize`.
        let dpi = 72 * max(1, CGFloat(max(image.width, image.height)) / maxSize)
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
