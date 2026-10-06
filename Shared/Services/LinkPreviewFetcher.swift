import Foundation
import LinkPresentation
import SwiftData
import UniformTypeIdentifiers

/// Fetches a link's page title and image with LinkPresentation. Compiled into the Mac and iPhone apps only:
/// `project.yml` keeps it out of the keyboard, widget and Share extensions, which never fetch.
enum LinkPreviewFetcher {
    /// `preview` is final: the page's title and image, either or both nil when it has none or the fetch failed for
    /// good. `retry` is offline or timed out, worth another try later.
    enum Outcome: Equatable, Sendable {
        case preview(title: String?, image: Data?)
        case retry
    }

    /// One fetch, `LinkPreviewPlan.timeout` at most. The image is the page's, else its icon, downsampled off the
    /// cooperative pool. Never call it with a secret's URL: `LinkPreviewPlan.nextBatch` leaves them out.
    static func fetch(_ url: URL) async -> Outcome {
        let provider = LPMetadataProvider()
        provider.timeout = LinkPreviewPlan.timeout
        let metadata: LPLinkMetadata
        do {
            metadata = try await provider.startFetchingMetadata(for: url)
        } catch {
            return LinkPreviewPlan.outcome(for: error) == .retry ? .retry : .preview(title: nil, image: nil)
        }
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var raw = await data(from: metadata.imageProvider)
        if raw == nil { raw = await data(from: metadata.iconProvider) }
        var image: Data?
        if let raw { image = await ImageTextQueue.offMain { LinkPreviewPlan.image(from: raw) } }
        return .preview(title: title?.isEmpty == false ? title : nil, image: image)
    }

    private static func data(from provider: NSItemProvider?) async -> Data? {
        guard let provider, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// Fetches previews for link clips, newest first, one `LinkPreviewPlan` batch at a time, the way `ImageTextQueue` reads
/// images. The store is read on a utility dispatch queue with its own `ModelContext`; the fetch runs off the main actor.
/// Results are written on the main context, then `save` stores them without queueing an upload: the fields never sync.
@MainActor final class LinkPreviewQueue {
    private let container: ModelContainer
    private let isEnabled: @MainActor () -> Bool
    private let fetch: @Sendable (URL) async -> LinkPreviewFetcher.Outcome
    private let save: @MainActor (Set<UUID>) -> Void
    /// The running pass. Never more than one: a `fill` meanwhile makes it go round once more.
    private(set) var task: Task<Void, Never>?
    private var again = false

    init(container: ModelContainer,
         isEnabled: @escaping @MainActor () -> Bool = { LinkPreviewPlan.isEnabled },
         fetch: @escaping @Sendable (URL) async -> LinkPreviewFetcher.Outcome = { await LinkPreviewFetcher.fetch($0) },
         save: @escaping @MainActor (Set<UUID>) -> Void) {
        self.container = container
        self.isEnabled = isEnabled
        self.fetch = fetch
        self.save = save
    }

    /// Fetches the newest links not fetched yet: after a capture, at launch, after a sync, on return to the foreground.
    /// Nothing while "Link previews" is off.
    func fill() {
        guard isEnabled() else { return }
        again = true
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    /// Ends the pass after the fetch in flight, keeping what it already fetched.
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
        let container = container, fetch = fetch
        var last: [UUID] = []
        // Offline or timed out in this pass: left for the next `fill`, never retried batch after batch.
        var failed: Set<UUID> = []
        while !Task.isCancelled {
            let skipped = failed
            let batch = await ImageTextQueue.offMain { Self.nextBatch(in: container, skipping: skipped) }
            // The same batch again means the last write didn't land: stop rather than fetch it forever.
            guard !batch.isEmpty, batch.map(\.id) != last else { return }
            last = batch.map(\.id)
            var results: [Result] = []
            for clip in batch {
                if Task.isCancelled { break }
                guard let url = LinkPreviewPlan.fetchableURL(clip.url) else { continue }
                switch await fetch(url) {
                case .preview(let title, let image): results.append(Result(id: clip.id, url: clip.url, title: title, image: image))
                case .retry: failed.insert(clip.id)
                }
            }
            write(results)
        }
    }

    private struct Result {
        let id: UUID
        /// The text fetched, so a preview never lands on a clip edited meanwhile.
        let url: String
        let title: String?
        let image: Data?
    }

    /// Stores each preview, or none, and marks the clip fetched. Skips a clip deleted, edited or made a secret meanwhile.
    private func write(_ results: [Result]) {
        let context = container.mainContext
        // A pending user change goes out in a save the tracker reports, before the save that hides these clips from it.
        if context.hasChanges { try? context.save() }
        var written: Set<UUID> = []
        for result in results {
            guard let clip = context.syncClip(id: result.id), !clip.isGone, !clip.isSensitive,
                  clip.textContent == result.url else { continue }
            clip.linkTitle = result.title
            clip.linkImageData = result.image
            clip.linkPreviewDone = true
            written.insert(result.id)
        }
        if !written.isEmpty { save(written) }
    }

    nonisolated private static func nextBatch(in container: ModelContainer,
                                              skipping failed: Set<UUID>) -> [(id: UUID, url: String)] {
        let link = ContentType.url.rawValue
        var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentTypeRaw == link },
                                                   sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        fetch.fetchLimit = LinkPreviewPlan.window
        fetch.propertiesToFetch = [\.id, \.contentTypeRaw, \.textContent, \.isSensitive, \.linkPreviewDone, \.copiedAt]
        let clips = (try? ModelContext(container).fetch(fetch)) ?? []
        let candidates = clips.map {
            LinkPreviewPlan.Candidate(id: $0.id, isLink: $0.contentType == .url, isSensitive: $0.isSensitive,
                                      isDone: $0.linkPreviewDone, copiedAt: $0.copiedAt, url: $0.textContent)
        }
        let urls = Dictionary(candidates.map { ($0.id, $0.url ?? "") }, uniquingKeysWith: { first, _ in first })
        return LinkPreviewPlan.nextBatch(clips: candidates, skipping: failed).map { ($0, urls[$0] ?? "") }
    }
}
