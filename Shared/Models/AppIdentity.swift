import CoreGraphics
import Foundation
import SwiftData

/// A source app's name, icon and header color, published by the Mac that has the app so the iPhone (which can't read
/// other apps' icons) and other Macs can show it. Synced as the CloudKit record type `AppIdentity`.
@Model
final class AppIdentity {
    /// Random, and the record's name, like a clip's (ruling R6): record names are not encrypted, so they must never say
    /// which apps the user copies from. A fetched record keeps its own.
    var id: UUID
    /// Unique by code: the Mac publishes over the identity it has, and the applier keeps the newest of two records for
    /// one app (`AppIdentityPublisher.wins`).
    var bundleId: String
    var name: String
    /// A 128×128 PNG.
    @Attribute(.externalStorage) var iconPNG: Data
    /// "#RRGGBB", `IconColor.dominant` of the icon.
    var colorHex: String
    var updatedAt: Date
    var syncSystemFields: Data?

    init(id: UUID = UUID(), bundleId: String, name: String, iconPNG: Data, colorHex: String, updatedAt: Date = .now) {
        self.id = id
        self.bundleId = bundleId
        self.name = name
        self.iconPNG = iconPNG
        self.colorHex = colorHex
        self.updatedAt = updatedAt
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
    /// A device updated after the Mac published gets the icons within this. ponytail: the App Store build should add a
    /// one-time backfill (publish every app in the history) instead of waiting for the refresh.
    static let refreshAfter: TimeInterval = 7 * 86_400

    /// Only the Mac uploads identities. The iPhone can't read other apps' icons, so it only reads the Mac's: its
    /// tracker and re-queue skip them, and a stale copy on the phone can never overwrite a newer one.
    #if os(macOS)
    static let publishesHere = true
    #else
    static let publishesHere = false
    #endif

    /// None yet, or older than 7 days. Never Copyd itself, and never from a secret: it stays on this Mac, and so does
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

    /// Two records for one app (two Macs published it, each under its own name): every device keeps `a` over `b` when
    /// it is newer, and on a tie when its name sorts first.
    static func wins(_ a: (updatedAt: Date, id: UUID), over b: (updatedAt: Date, id: UUID)) -> Bool {
        a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.id.uuidString < b.id.uuidString
    }
}
