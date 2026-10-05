import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image clip bytes ready for `UIPasteboard`, without decoding a full-resolution bitmap:
/// the keyboard extension is killed past roughly 50 MB, and a decoded 5K screenshot alone is about 59 MB.
enum PasteboardImage {
    private static let passThrough: Set<String> = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier]

    /// PNG/JPEG/HEIC pass through untouched (no decode); anything else is transcoded to PNG with ImageIO, longest side ≤ maxPixels.
    static func payload(from data: Data, maxPixels: Int) -> (data: Data, uti: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else { return nil }
        if passThrough.contains(type) { return (data, type) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, UTType.png.identifier)
    }
}
