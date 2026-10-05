import AppKit
import Foundation

struct ThumbnailImageCache {
    private nonisolated(unsafe) static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 180
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    static func image(for item: ClipboardItem) -> NSImage? {
        let cacheKey = item.id.uuidString as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let data = item.thumbnailData ?? item.rawData
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: cacheKey, cost: data.count)
        return image
    }
}
