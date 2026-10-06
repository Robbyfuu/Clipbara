import CoreSpotlight
import OSLog
import SwiftData
import UniformTypeIdentifiers

/// Keeps the clips in Spotlight (spec §3): domain `clips`, one entry per clip, keyed by its UUID string, built by
/// `SpotlightPlan`. Every main-context save passes through here, so the index follows local saves, sync-applied changes
/// and deletes, the secret sweep, the Share inbox and the user's deletes. The iPhone app only: no extension compiles it.
@MainActor final class SpotlightIndexer {
    nonisolated static let domain = "clips"
    /// "Show in Spotlight", on by default. In the App Group, like "Link previews".
    nonisolated static let enabledDefaultsKey = "spotlightEnabled"
    /// The index version, stored only while the index is in step with the store (`SpotlightPlan.JobLedger`). Missing or
    /// another version at launch: every entry is rebuilt. Raise `version` after a change to what an entry holds.
    nonisolated static let versionDefaultsKey = "spotlightIndexVersion"
    nonisolated static let version = 1
    static var isEnabled: Bool { SecretDetector.settings.object(forKey: enabledDefaultsKey) as? Bool ?? true }

    private nonisolated static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "Spotlight")
    /// An update reads and indexes this many clips at a time.
    private nonisolated static let chunk = 200
    /// The longest side, in pixels, of a result's thumbnail.
    private nonisolated static let thumbnailPixels: CGFloat = 180

    private let container: ModelContainer
    private let indexed = SpotlightPlan.IndexedRecords()
    private var ledger = SpotlightPlan.JobLedger()
    private var observer: SpotlightPlan.SaveObserver?
    /// The last job queued. Each waits for the one before, so a delete never lands before the entry it removes.
    private var last: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
        observer = SpotlightPlan.SaveObserver(context: container.mainContext) { [weak self] saved, deleted in
            guard Self.isEnabled, let self else { return }
            enqueue { [indexed] in try await Self.update(saved: Array(saved), deleted: Array(deleted), in: $0, indexed: indexed) }
        }
        // A new version, or a queue a kill or a failed job left unfinished: bring the index in step with the store.
        if SecretDetector.settings.integer(forKey: Self.versionDefaultsKey) != Self.version {
            if Self.isEnabled { rebuild() } else { removeAll() }
        }
    }

    /// Saves inside `save` never reindex `ids`: the type and topic passes store fields Spotlight never shows.
    func ignoring(_ ids: Set<UUID>, _ save: () -> Void) {
        guard let observer else { return save() }
        observer.ignoring(ids, save)
    }

    /// Every entry again, from the store: on a new index version, when "Show in Spotlight" is turned back on, and when
    /// "Link previews" changes what a link shows. Nothing while "Show in Spotlight" is off.
    func rebuild() {
        guard Self.isEnabled else { return }
        enqueue(resets: true) { [indexed] container in
            indexed.removeAll()
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain])
            // Newest first, so recent clips are searchable soonest.
            var fetch = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
            fetch.propertiesToFetch = [\.id]
            let ids = try ModelContext(container).fetch(fetch).map(\.id)
            try await Self.update(saved: ids, deleted: [], in: container, indexed: indexed)
            Self.log.notice("Spotlight rebuilt: \(ids.count, privacy: .public) clips read")
        }
    }

    /// Removes every entry: "Show in Spotlight" turned off, or the local mirror wiped (account change, zone deleted).
    func removeAll() {
        enqueue(resets: true) { [indexed] _ in
            indexed.removeAll()
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain])
        }
    }

    #if DEBUG
    /// `-CopydSpotlightCheck YES`, with `-CopydSeedSampleClips YES -CopydSeedSecretClip YES -iCloudSyncEnabled NO`: once
    /// the queued jobs finish, asks Spotlight for the seeded text and for every Copyd entry, and logs whether the text
    /// clip is found and the secret is not. New entries take a moment to become searchable, so it asks up to 10 times.
    func checkIfRequested() {
        guard UserDefaults.standard.bool(forKey: "CopydSpotlightCheck") else { return }
        let seeds = (try? container.mainContext.fetch(FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.contentHash == "seed-short" || $0.contentHash == "seed-secret" }))) ?? []
        guard let text = seeds.first(where: { !$0.isSensitive })?.id.uuidString,
              let secret = seeds.first(where: \.isSensitive)?.id.uuidString else {
            return Self.log.error("Spotlight check: seed clips missing")
        }
        Task {
            await last?.value
            for attempt in 1...10 {
                let byText = await Self.titles(matching: #"title == "Hello from*"cd"#)
                let all = await Self.titles(matching: #"title == "*""#)
                let found = byText[text] != nil, leaked = all[secret] != nil || byText[secret] != nil
                if found || attempt == 10 {
                    let titles = all.values.sorted().joined(separator: " | ")
                    Self.log.notice("""
                        Spotlight check \(found && !leaked ? "PASS" : "FAIL", privacy: .public) (attempt \(attempt, privacy: .public)): \
                        text found=\(found, privacy: .public), secret indexed=\(leaked, privacy: .public), \
                        entries=\(all.count, privacy: .public): \(titles, privacy: .public)
                        """)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Copyd's entries matching `query`, by identifier, with their titles.
    private nonisolated static func titles(matching query: String) async -> [String: String] {
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title"]
        var found: [String: String] = [:]
        do {
            for try await result in CSSearchQuery(queryString: query, queryContext: context).results {
                found[result.item.uniqueIdentifier] = result.item.attributeSet.title ?? ""
            }
        } catch {
            log.error("Spotlight check query failed: \(error.localizedDescription, privacy: .public)")
        }
        return found
    }
    #endif

    /// Queues `job` after the others. `resets`: a rebuild or a clear, which brings the index in step on its own.
    private func enqueue(resets: Bool = false, _ job: @escaping @Sendable (ModelContainer) async throws -> Void) {
        // Cleared before the job can start, so a kill from here until the queue drains rebuilds on the next launch.
        if ledger.start() { SecretDetector.settings.removeObject(forKey: Self.versionDefaultsKey) }
        let previous = last, container = container
        last = Task.detached(priority: .utility) { [weak self] in
            await previous?.value
            var succeeded = true
            do { try await job(container) } catch {
                succeeded = false
                Self.log.error("Spotlight update failed: \(error.localizedDescription, privacy: .public)")
            }
            await self?.finished(succeeded: succeeded, resets: resets)
        }
    }

    private func finished(succeeded: Bool, resets: Bool) {
        if ledger.finish(succeeded: succeeded, resets: resets) {
            SecretDetector.settings.set(Self.version, forKey: Self.versionDefaultsKey)
        }
    }

    /// Removes `deleted`, then indexes `saved` as the store holds them now, `chunk` clips at a time, so a large save never
    /// makes one huge fetch or index call.
    private nonisolated static func update(saved: [UUID], deleted: [UUID], in container: ModelContainer,
                                           indexed: SpotlightPlan.IndexedRecords) async throws {
        let index = CSSearchableIndex.default()
        try await remove(deleted, from: index, indexed: indexed)
        for start in stride(from: 0, to: saved.count, by: chunk) {
            let part = Array(saved[start..<min(start + chunk, saved.count)])
            let (items, records, removed) = try entries(saved: part, in: container, indexed: indexed)
            try await remove(removed, from: index, indexed: indexed)
            guard !items.isEmpty else { continue }
            try await index.indexSearchableItems(items)
            indexed.stored(records)
        }
    }

    private nonisolated static func remove(_ ids: [UUID], from index: CSSearchableIndex,
                                           indexed: SpotlightPlan.IndexedRecords) async throws {
        guard !ids.isEmpty else { return }
        try await index.deleteSearchableItems(withIdentifiers: ids.map(\.uuidString))
        indexed.removed(ids)
    }

    /// Reads `ids` from the store: the items to index with their records, and the ids to remove (no entry any more, or
    /// deleted by a later save). A record Spotlight already holds unchanged is skipped before its thumbnail is made.
    private nonisolated static func entries(saved ids: [UUID], in container: ModelContainer, indexed: SpotlightPlan.IndexedRecords)
        throws -> (items: [CSSearchableItem], records: [SpotlightRecord], removed: [UUID]) {
        // Bound for the whole read: the thumbnails are external storage, loaded from this context when read.
        let context = ModelContext(container)
        let clips = try context.fetch(FetchDescriptor<ClipboardItem>(predicate: #Predicate { ids.contains($0.id) }))
        let linkPreviews = LinkPreviewPlan.isEnabled
        let plan = SpotlightPlan.changes(saved: clips.map { SpotlightPlan.Input($0, linkPreviews: linkPreviews) },
                                         deleted: Array(Set(ids).subtracting(clips.map(\.id))))
        let records = indexed.changed(plan.upsert)
        let byID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = records.map { record in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = record.title
            if !record.summary.isEmpty { attributes.contentDescription = record.summary }
            let source: Data? = switch record.thumbnailSource {
            case .image: byID[record.id]?.thumbnailData
            case .link: byID[record.id]?.linkImageData
            case .none: nil
            }
            attributes.thumbnailData = source.flatMap { Thumbnail.jpeg(from: $0, maxPixels: thumbnailPixels, quality: 0.7) }
            let item = CSSearchableItem(uniqueIdentifier: record.id.uuidString, domainIdentifier: domain, attributeSet: attributes)
            item.expirationDate = .distantFuture  // the default is a month; an entry stays until its clip is deleted
            return item
        }
        return (items, records, plan.delete)
    }
}
