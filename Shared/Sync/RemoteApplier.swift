import Foundation
import OSLog
import SwiftData

/// Writes records fetched from iCloud into the local store. Never saves: the caller saves inside
/// `tracker.suppressing(outcome.touched)`, so `touched` holds every id inserted, updated or deleted,
/// including entries removed by a cascade or by deleting a clip.
@MainActor
struct RemoteApplier {
    let context: ModelContext
    let hasPendingSave: (UUID) -> Bool

    struct Outcome: Equatable {
        var saves: Set<UUID> = []
        var deletes: Set<UUID> = []
        var orphans: [EntrySnapshot] = []
        var touched: Set<UUID> = []
    }

    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "Sync")

    func apply(clips: [ClipSnapshot], pinboards: [PinboardSnapshot], entries: [EntrySnapshot],
               deletions: [UUID], systemFields: [UUID: Data]) -> Outcome {
        var out = Outcome()
        for s in clips {
            do { try upsert(s, &out) } catch { Self.log.error("Clip \(s.id, privacy: .public) not applied: \(error.syncLogDescription, privacy: .public)") }
        }
        for s in pinboards {
            do { try upsert(s, &out) } catch { Self.log.error("Pinboard \(s.id, privacy: .public) not applied: \(error.syncLogDescription, privacy: .public)") }
        }
        for s in entries {
            do { try upsert(s, &out) } catch { Self.log.error("Entry \(s.id, privacy: .public) not applied: \(error.syncLogDescription, privacy: .public)") }
        }
        // After entries, so a same-batch entry of a losing clip is moved to the survivor, not orphaned.
        for s in clips {
            do { try mergeDuplicates(of: s.id, &out) } catch { Self.log.error("Merge for \(s.id, privacy: .public) failed: \(error.syncLogDescription, privacy: .public)") }
        }
        for id in deletions {
            do { try delete(id, &out) } catch { Self.log.error("Deletion \(id, privacy: .public) not applied: \(error.syncLogDescription, privacy: .public)") }
        }
        let gone = out.deletes.union(deletions)
        for (id, data) in systemFields where !gone.contains(id) {
            do {
                if let m = try clip(id) {
                    m.syncSystemFields = data
                } else if let m = try pinboard(id) {
                    m.syncSystemFields = data
                } else if let m = try entry(id) {
                    m.syncSystemFields = data
                } else {
                    continue
                }
                out.touched.insert(id)
            } catch { Self.log.error("System fields for \(id, privacy: .public) not stored: \(error.syncLogDescription, privacy: .public)") }
        }
        return out
    }

    /// Does not save. The caller must save inside `tracker.suppressing` over all ids.
    static func clearSystemFields(in context: ModelContext) {
        do {
            for m in try context.fetch(FetchDescriptor<ClipboardItem>()) { m.syncSystemFields = nil }
            for m in try context.fetch(FetchDescriptor<Pinboard>()) { m.syncSystemFields = nil }
            for m in try context.fetch(FetchDescriptor<PinboardEntry>()) { m.syncSystemFields = nil }
        } catch { log.error("clearSystemFields failed: \(error.syncLogDescription, privacy: .public)") }
    }

    /// Records that should be in iCloud. `onlyUnconfirmed` keeps those the server never accepted (`syncSystemFields == nil`).
    /// File clips never sync, and neither do entries pointing at them.
    static func uploadableIDs(in context: ModelContext, onlyUnconfirmed: Bool) throws -> [UUID] {
        // Type only: rawData is external storage and is never read here.
        let clips = try context.fetch(FetchDescriptor<ClipboardItem>())
            .filter { $0.contentTypeRaw != "fileURL" && (!onlyUnconfirmed || $0.syncSystemFields == nil) }.map(\.id)
        let boards = try context.fetch(FetchDescriptor<Pinboard>())
            .filter { !onlyUnconfirmed || $0.syncSystemFields == nil }.map(\.id)
        let entries = try context.fetch(FetchDescriptor<PinboardEntry>())
            .filter { $0.clipboardItem?.contentTypeRaw != "fileURL" && (!onlyUnconfirmed || $0.syncSystemFields == nil) }.map(\.id)
        return clips + boards + entries
    }

    /// Deletes every clip, pinboard and entry and returns their ids. Does not save: the caller saves
    /// inside `tracker.suppressing` over the returned ids.
    static func deleteAll(in context: ModelContext) -> Set<UUID> {
        var ids: Set<UUID> = []
        do {
            for m in try context.fetch(FetchDescriptor<PinboardEntry>()) { ids.insert(m.id); context.delete(m) }
            for m in try context.fetch(FetchDescriptor<Pinboard>()) { ids.insert(m.id); context.delete(m) }
            for m in try context.fetch(FetchDescriptor<ClipboardItem>()) { ids.insert(m.id); context.delete(m) }
        } catch { log.error("deleteAll failed: \(error.syncLogDescription, privacy: .public)") }
        return ids
    }

    // MARK: Lookups (throwing: a fetch error must never read as "not found")

    private func clip(_ id: UUID) throws -> ClipboardItem? {
        var d = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    private func pinboard(_ id: UUID) throws -> Pinboard? {
        var d = FetchDescriptor<Pinboard>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    private func entry(_ id: UUID) throws -> PinboardEntry? {
        var d = FetchDescriptor<PinboardEntry>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try context.fetch(d).first
    }

    // ponytail: in-memory filter over all entries; pinboards are small, add a predicate if that changes.
    private func entries(ofClip id: UUID, excluding gone: Set<UUID>) throws -> [PinboardEntry] {
        try context.fetch(FetchDescriptor<PinboardEntry>())
            .filter { $0.clipboardItem?.id == id && !gone.contains($0.id) }
    }

    // MARK: Upserts

    private func upsert(_ s: ClipSnapshot, _ out: inout Outcome) throws {
        out.touched.insert(s.id)
        if let m = try clip(s.id) {
            if hasPendingSave(s.id) { return }
            // Thumbnails never sync: images and file clips with an image file get one from their data.
            if m.update(from: s) { m.thumbnailData = Thumbnail.png(for: m.contentType, rawData: s.rawData) }
        } else {
            let m = ClipboardItem(contentType: ContentType(rawValue: s.contentType) ?? .unknown,
                                  rawData: s.rawData, contentHash: s.contentHash)
            m.id = s.id
            m.update(from: s)
            m.thumbnailData = Thumbnail.png(for: m.contentType, rawData: s.rawData)
            context.insert(m)
        }
    }

    private func upsert(_ s: PinboardSnapshot, _ out: inout Outcome) throws {
        out.touched.insert(s.id)
        if let m = try pinboard(s.id) {
            if !hasPendingSave(s.id) { m.update(from: s) }
        } else {
            let m = Pinboard(name: s.name, displayOrder: s.displayOrder)
            m.id = s.id
            m.update(from: s)
            context.insert(m)
        }
    }

    private func upsert(_ s: EntrySnapshot, _ out: inout Outcome) throws {
        let existing = try entry(s.id)
        if existing != nil && hasPendingSave(s.id) { return }
        guard let c = try clip(s.clipID), let p = try pinboard(s.pinboardID) else {
            out.orphans.append(s)
            return
        }
        out.touched.insert(s.id)
        // Linking updates the inverse Pinboard.entries, so the local tracker sees those pinboards as changed too.
        out.touched.insert(p.id)
        if let m = existing {
            m.displayOrder = s.displayOrder
            m.addedAt = s.addedAt
            if m.clipboardItem?.id != c.id { m.clipboardItem = c }
            if m.pinboard?.id != p.id {
                if let old = m.pinboard?.id { out.touched.insert(old) }
                m.pinboard = p
            }
        } else {
            let m = PinboardEntry(clipboardItem: c, pinboard: p, displayOrder: s.displayOrder)
            m.id = s.id
            m.addedAt = s.addedAt
            context.insert(m)
        }
    }

    // MARK: Duplicates (spec section 10)

    private func mergeDuplicates(of id: UUID, _ out: inout Outcome) throws {
        guard let incoming = try clip(id), !out.deletes.contains(id) else { return }
        let hash = incoming.contentHash
        let others = try context.fetch(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentHash == hash }))
        for other in others where other.id != id && !out.deletes.contains(other.id) {
            if out.deletes.contains(id) { break }
            guard let merge = DuplicateRule.merge(incoming.snapshot, other.snapshot) else { continue }
            let survivor = merge.survivorID == id ? incoming : other
            let loser = merge.loserID == id ? incoming : other
            survivor.isPinned = merge.isPinned
            survivor.userTitle = merge.userTitle
            survivor.copiedAt = merge.copiedAt
            out.saves.insert(survivor.id)
            out.touched.insert(survivor.id)
            var survivorBoards = Set(try entries(ofClip: survivor.id, excluding: out.deletes).compactMap { $0.pinboard?.id })
            for e in try entries(ofClip: loser.id, excluding: out.deletes) {
                out.touched.insert(e.id)
                if let pid = e.pinboard?.id, survivorBoards.contains(pid) {
                    out.touched.insert(pid)
                    context.delete(e)
                    out.deletes.insert(e.id)
                } else {
                    e.clipboardItem = survivor
                    if let pid = e.pinboard?.id { survivorBoards.insert(pid) }
                    out.saves.insert(e.id)
                }
            }
            context.delete(loser)
            out.deletes.insert(loser.id)
            out.touched.insert(loser.id)
        }
    }

    // MARK: Deletions

    private func delete(_ id: UUID, _ out: inout Outcome) throws {
        if let c = try clip(id) {
            for e in try entries(ofClip: id, excluding: out.deletes) {
                if let pid = e.pinboard?.id { out.touched.insert(pid) }
                context.delete(e)
                out.touched.insert(e.id)
            }
            context.delete(c)
        } else if let p = try pinboard(id) {
            for e in p.entries { out.touched.insert(e.id) }
            context.delete(p)
        } else if let e = try entry(id) {
            if let pid = e.pinboard?.id { out.touched.insert(pid) }
            context.delete(e)
        } else {
            return
        }
        out.touched.insert(id)
    }
}
