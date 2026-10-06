import AppKit
import SwiftData
import UniformTypeIdentifiers

struct AppIconProvider {
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()

    /// Where synced identities are read: the app's main context, set once at launch.
    @MainActor static var store: ModelContext?

    /// The installed app's icon, else the one its synced identity carries (an app only on another Mac), else a generic
    /// symbol. The symbol is never cached, so an identity that syncs later shows.
    @MainActor static func icon(for bundleId: String?, size: CGFloat = 16) -> NSImage {
        let cacheKey = "\(bundleId ?? ""):\(Int(size))" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        guard let bundleId, let icon = knownIcon(bundleId) else {
            let icon = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            icon.size = NSSize(width: size, height: size)
            return icon
        }
        icon.size = NSSize(width: size, height: size)
        cache.setObject(icon, forKey: cacheKey)
        return icon
    }

    /// A fresh image each call: `icon(for:size:)` sets each cached size's own.
    @MainActor private static func knownIcon(_ bundleId: String) -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return synced(bundleId).flatMap { NSImage(data: $0.iconPNG) }
    }

    @MainActor private static func synced(_ bundleId: String) -> AppIdentity? {
        guard let store else { return nil }
        return try? AppIdentity.find(bundleId, in: store)
    }

    // MARK: - Card header look

    /// A source app's header icon and color.
    struct Look {
        let icon: NSImage
        let color: RGB
        /// From an identity synced from another Mac, not the app installed here.
        var isSynced = false
    }

    /// Per bundle id; nil when the app is unknown here. Cleared after a sync applies, so a newly synced identity shows.
    @MainActor private static var looks: [String: Look?] = [:]

    /// The live icon of an app installed here wins; an identity synced from another Mac covers one that isn't. Nil
    /// for neither, or no source app: the header then falls back to butter and the Copyd mark.
    @MainActor static func look(for bundleId: String?) -> Look? {
        guard let bundleId else { return nil }
        if let cached = looks[bundleId] { return cached }
        let look: Look?
        let live = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil ? icon(for: bundleId, size: 128) : nil
        if let live, let art = art(for: live) {
            look = Look(icon: live, color: art.color)
        } else if let synced = synced(bundleId), let image = NSImage(data: synced.iconPNG),
                  let color = RGB(hex: synced.colorHex) {
            look = Look(icon: image, color: color, isSynced: true)
        } else {
            look = nil
        }
        looks[bundleId] = look
        return look
    }

    /// After a sync: apps still unknown here, and those shown with a synced icon (refreshed, or now installed), are
    /// looked up again. The icon cache is emptied for the same reason; installed icons cost one NSWorkspace read each.
    @MainActor static func forgetLooks() {
        looks = looks.filter { $0.value.map { !$0.isSynced } ?? false }
        cache.removeAllObjects()
    }

    /// The installed app's icon as a 128×128 PNG, with its `IconColor.dominant`: what the Mac publishes as an
    /// `AppIdentity`. Nil when the app isn't installed. Safe off the main thread.
    nonisolated static func identityArt(for bundleId: String) -> (png: Data, color: RGB)? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
              let art = art(for: NSWorkspace.shared.icon(forFile: url.path)) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, art.image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, art.color)
    }

    /// `icon` drawn at 128×128 px, and the dominant color of those pixels.
    private nonisolated static func art(for icon: NSImage) -> (image: CGImage, color: RGB)? {
        let side = 128
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let source = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let image = ctx.makeImage(), let data = ctx.data else { return nil }
        let rgba = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: side * side * 4))
        return (image, IconColor.dominant(rgba: rgba, width: side, height: side))
    }
}
