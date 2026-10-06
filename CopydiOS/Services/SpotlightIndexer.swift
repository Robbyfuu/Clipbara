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
    /// The index version last built. Raise `version` to rebuild every entry on the next launch.
    nonisolated static let versionDefaultsKey = "spotlightIndexVersion"
    nonisolated static let version = 1
    static var isEnabled: Bool { SecretDetector.settings.object(forKey: enabledDefaultsKey) as? Bool ?? true }

    private nonisolated static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "Spotlight")
    /// A rebuild reads and indexes this many clips at a time.
    private nonisolated static let chunk = 200

    private let container: ModelContainer
    private var observer: SpotlightPlan.SaveObserver?
    /// The last job queued. Each waits for the one before, so a delete never lands before the entry it removes.
    private var last: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
        observer = SpotlightPlan.SaveObserver(context: container.mainContext) { [weak self] saved, deleted in
            guard Self.isEnabled else { return }
            self?.enqueue { try await Self.update(saved: saved, deleted: deleted, in: $0) }
        }
        if SecretDetector.settings.integer(forKey: Self.versionDefaultsKey) != Self.version { rebuild() }
    }

    /// Every entry again, from the store: on a new index version, when "Show in Spotlight" is turned back on, and when
    /// "Link previews" changes what a link shows. Nothing while "Show in Spotlight" is off.
    func rebuild() {
        guard Self.isEnabled else { return }
        enqueue { container in
            try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain])
            var fetch = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
            fetch.propertiesToFetch = [\.id]
            let ids = try ModelContext(container).fetch(fetch).map(\.id)
            for start in stride(from: 0, to: ids.count, by: Self.chunk) {
                try await Self.update(saved: Set(ids[start..<min(start + Self.chunk, ids.count)]), deleted: [], in: container)
            }
            SecretDetector.settings.set(Self.version, forKey: Self.versionDefaultsKey)
            Self.log.notice("Spotlight rebuilt: \(ids.count, privacy: .public) clips read")
        }
    }

    /// Removes every entry: "Show in Spotlight" turned off, or the local mirror wiped (account change, zone deleted).
    func removeAll() {
        enqueue { _ in try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain]) }
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

    private func enqueue(_ job: @escaping @Sendable (ModelContainer) async throws -> Void) {
        let previous = last, container = container
        last = Task.detached(priority: .utility) {
            await previous?.value
            do { try await job(container) } catch {
                Self.log.error("Spotlight update failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Indexes `saved` as the store holds them now, and removes `deleted`.
    private nonisolated static func update(saved: Set<UUID>, deleted: Set<UUID>, in container: ModelContainer) async throws {
        let (items, removed) = try entries(saved: saved, deleted: deleted, in: container)
        let index = CSSearchableIndex.default()
        if !removed.isEmpty { try await index.deleteSearchableItems(withIdentifiers: removed) }
        if !items.isEmpty { try await index.indexSearchableItems(items) }
    }

    /// Reads `saved` from the store: the items to index, and the identifiers to remove. A clip no longer in the store was
    /// deleted by a later save; it is removed here too.
    private nonisolated static func entries(saved: Set<UUID>, deleted: Set<UUID>,
                                            in container: ModelContainer) throws -> ([CSSearchableItem], [String]) {
        let ids = Array(saved)
        // Bound for the whole read: the thumbnails are external storage, loaded from this context when read.
        let context = ModelContext(container)
        let clips = ids.isEmpty ? [] : try context.fetch(FetchDescriptor<ClipboardItem>(predicate: #Predicate { ids.contains($0.id) }))
        let linkPreviews = LinkPreviewPlan.isEnabled
        let plan = SpotlightPlan.changes(saved: clips.map { SpotlightPlan.Input($0, linkPreviews: linkPreviews) },
                                         deleted: Array(deleted.union(saved.subtracting(clips.map(\.id)))))
        let byID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items = plan.upsert.map { record in
            let attributes = CSSearchableItemAttributeSet(contentType: .text)
            attributes.title = record.title
            if !record.summary.isEmpty { attributes.contentDescription = record.summary }
            switch record.thumbnailSource {
            case .image: attributes.thumbnailData = byID[record.id]?.thumbnailData
            case .link: attributes.thumbnailData = byID[record.id]?.linkImageData
            case .none: break
            }
            let item = CSSearchableItem(uniqueIdentifier: record.id.uuidString, domainIdentifier: domain, attributeSet: attributes)
            item.expirationDate = .distantFuture  // the default is a month; an entry stays until its clip is deleted
            return item
        }
        return (items, plan.delete.map(\.uuidString))
    }
}
