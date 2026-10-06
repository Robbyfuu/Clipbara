import AppKit
import SwiftData
import UniformTypeIdentifiers

struct AppIconProvider {
    private nonisolated(unsafe) static let cache = NSCache<NSString, NSImage>()

    static func icon(for bundleId: String?, size: CGFloat = 16) -> NSImage {
        guard let bundleId else {
            let icon = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            icon.size = NSSize(width: size, height: size)
            return icon
        }

        let cacheKey = "\(bundleId):\(Int(size))" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        let icon: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        icon.size = NSSize(width: size, height: size)
        cache.setObject(icon, forKey: cacheKey)
        return icon
    }

    // MARK: - Card header look

    /// A source app's header icon and color.
    struct Look {
        let icon: NSImage
        let color: RGB
    }

    /// Per bundle id; nil when the app is unknown here. Cleared after a sync applies, so a newly synced identity shows.
    @MainActor private static var looks: [String: Look?] = [:]

    /// The live icon of an app installed here wins; an identity synced from another Mac covers one that isn't. Nil
    /// for neither, or no source app: the header then falls back to butter and the Copyd mark.
    @MainActor static func look(for bundleId: String?, in context: ModelContext) -> Look? {
        guard let bundleId else { return nil }
        if let cached = looks[bundleId] { return cached }
        let look: Look?
        let live = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil ? icon(for: bundleId, size: 128) : nil
        if let live, let art = art(for: live) {
            look = Look(icon: live, color: art.color)
        } else if let synced = try? AppIdentity.find(bundleId, in: context), let image = NSImage(data: synced.iconPNG),
                  let color = RGB(hex: synced.colorHex) {
            look = Look(icon: image, color: color)
        } else {
            look = nil
        }
        looks[bundleId] = look
        return look
    }

    @MainActor static func forgetLooks() { looks = [:] }

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
