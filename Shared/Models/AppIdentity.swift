import CoreGraphics
import CryptoKit
import Foundation
import SwiftData

/// A source app's name, icon and header color, published by the Mac that has the app so the iPhone (which can't read
/// other apps' icons) and other Macs can show it. Synced as the CloudKit record type `AppIdentity`, one per bundle id.
@Model
final class AppIdentity {
    /// The sync layer's local key (tracker suppression, system fields): the first 16 bytes of the record name's hash,
    /// so every device gives one app the same id. Never synced: it follows from `bundleId`.
    var id: UUID
    /// Unique by code: one record name per bundle id, and the applier upserts by it.
    var bundleId: String
    var name: String
    /// A 128×128 PNG.
    @Attribute(.externalStorage) var iconPNG: Data
    /// "#RRGGBB", `IconColor.dominant` of the icon.
    var colorHex: String
    var updatedAt: Date
    var syncSystemFields: Data?

    init(bundleId: String, name: String, iconPNG: Data, colorHex: String, updatedAt: Date = .now) {
        self.id = Self.id(for: bundleId)
        self.bundleId = bundleId
        self.name = name
        self.iconPNG = iconPNG
        self.colorHex = colorHex
        self.updatedAt = updatedAt
    }

    /// `app-` plus the SHA-256 hex of the bundle id. Never change it: every device would upload a second record.
    static func recordName(for bundleId: String) -> String {
        "app-" + SHA256.hash(data: Data(bundleId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func id(for bundleId: String) -> UUID {
        let b = Array(SHA256.hash(data: Data(bundleId.utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func find(_ bundleId: String, in context: ModelContext) throws -> AppIdentity? {
        var d = FetchDescriptor<AppIdentity>(predicate: #Predicate { $0.bundleId == bundleId })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    /// The icons of the apps in `bundleIds` that have an identity, each decoded at most `maxPixels` on the longest
    /// side, never the PNG whole.
    static func icons(for bundleIds: Set<String>, maxPixels: CGFloat, in context: ModelContext) throws -> [String: CGImage] {
        guard !bundleIds.isEmpty else { return [:] }
        let wanted = Array(bundleIds)
        var out: [String: CGImage] = [:]
        for m in try context.fetch(FetchDescriptor<AppIdentity>(predicate: #Predicate { wanted.contains($0.bundleId) })) {
            out[m.bundleId] = Thumbnail.image(from: m.iconPNG, maxPixels: maxPixels)
        }
        return out
    }
}

/// When the Mac (re)publishes an app's identity on capture.
enum AppIdentityPublisher {
    static let refreshAfter: TimeInterval = 30 * 86_400

    /// Only the Mac uploads identities. The iPhone can't read other apps' icons, so it only reads the Mac's: its
    /// tracker and re-queue skip them, and a stale copy on the phone can never overwrite a newer one.
    #if os(macOS)
    static let publishesHere = true
    #else
    static let publishesHere = false
    #endif

    /// None yet, or older than 30 days. Never Copyd itself, and never from a secret: it stays on this Mac, and so does
    /// the app it came from.
    static func needsPublish(existing: Date?, now: Date, bundleId: String, ownBundleId: String,
                             isSensitive: Bool = false) -> Bool {
        guard bundleId != ownBundleId, !isSensitive else { return false }
        guard let existing else { return true }
        return now.timeIntervalSince(existing) > refreshAfter
    }

    /// A Mac's upload met another Mac's copy on the server: the newest wins, and a tie keeps the server's.
    static func serverWins(server: Date, local: Date) -> Bool {
        server >= local
    }
}
