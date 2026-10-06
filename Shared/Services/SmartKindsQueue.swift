import Foundation
import SwiftData

/// Sorts clips into the type boards (`SmartKinds`), newest first, one batch at a time. Like `ImageTextQueue`, the store
/// is read and the text scanned on a utility dispatch queue, each read with its own `ModelContext`. Results are written
/// on the main context, then `save` stores them without queueing an upload: the fields never sync. Compiled into the
/// Mac and iPhone apps only: `project.yml` keeps it out of the extensions, which only read the result.
@MainActor final class SmartKindsQueue {
    private let container: ModelContainer
    private let isEnabled: @MainActor () -> Bool
    private let save: @MainActor (Set<UUID>) -> Void
    /// The running pass. Never more than one: a `fill` meanwhile makes it go round once more.
    private(set) var task: Task<Void, Never>?
    private var again = false

    init(container: ModelContainer,
         isEnabled: @escaping @MainActor () -> Bool = { SmartKinds.isEnabled },
         save: @escaping @MainActor (Set<UUID>) -> Void) {
        self.container = container
        self.isEnabled = isEnabled
        self.save = save
    }

    /// Sorts the newest clips not sorted yet: after a capture or an edit, at launch, after a sync, on return to the
    /// foreground. Nothing while "Automatic pinboards" is off.
    func fill() {
        guard isEnabled() else { return }
        again = true
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    /// Ends the pass after the batch being sorted, keeping what it already wrote.
    func stop() {
        again = false
        task?.cancel()
    }

    private func drain() async {
        while again, !Task.isCancelled {
            again = false
            await pass()
        }
        task = nil
        if again { fill() }  // a `fill` after `stop`, while the stopped pass was finishing
    }

    private func pass() async {
        let container = container
        var last: [UUID] = []
        while !Task.isCancelled {
            let sorted = await ImageTextQueue.offMain { Self.sortNextBatch(in: container) }
            // The same batch again means the last write didn't land: stop rather than sort it forever.
            guard !sorted.isEmpty, sorted.map(\.id) != last else { return }
            last = sorted.map(\.id)
            write(sorted)
        }
    }

    private struct Sorted: Sendable {
        let id: UUID
        /// The content sorted, so a result never lands on a clip edited meanwhile.
        let contentHash: String
        let kinds: Int
    }

    /// Stores each clip's kinds and the classifier version. Skips a clip deleted or edited meanwhile.
    private func write(_ results: [Sorted]) {
        let context = container.mainContext
        // A pending user change goes out in a save the tracker reports, before the save that hides these clips from it.
        if context.hasChanges { try? context.save() }
        var written: Set<UUID> = []
        for result in results {
            guard let clip = context.syncClip(id: result.id), !clip.isGone, clip.contentHash == result.contentHash
            else { continue }
            clip.smartKinds = result.kinds
            clip.smartKindsVersion = SmartKinds.version
            written.insert(result.id)
        }
        if !written.isEmpty { save(written) }
    }

    /// The next batch, sorted. Only the batch's text is loaded: the window is read without it.
    nonisolated private static func sortNextBatch(in container: ModelContainer) -> [Sorted] {
        let context = ModelContext(container)
        var window = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        window.fetchLimit = SmartKinds.window
        window.propertiesToFetch = [\.id, \.smartKindsVersion, \.copiedAt]
        let clips = (try? context.fetch(window)) ?? []
        let ids = SmartKinds.nextBatch(clips: clips.map { ($0.id, $0.smartKindsVersion, $0.copiedAt) })
        guard !ids.isEmpty else { return [] }
        var batch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { ids.contains($0.id) })
        batch.propertiesToFetch = [\.id, \.contentTypeRaw, \.textContent, \.isSensitive, \.contentHash]
        let byID = Dictionary(((try? context.fetch(batch)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in
            guard let clip = byID[id] else { return nil }
            // A secret is sorted by its type only: its text never lands it in Code or Phones & Emails.
            let kinds = SmartKinds.classify(contentType: clip.contentType, text: clip.isSensitive ? nil : clip.textContent)
            return Sorted(id: id, contentHash: clip.contentHash, kinds: kinds)
        }
    }
}
