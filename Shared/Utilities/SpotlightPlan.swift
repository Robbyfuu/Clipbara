import Foundation
import os
import SwiftData

/// What Spotlight shows for a clip, and which index entries a save adds, refreshes or removes. CoreSpotlight itself
/// lives in the iPhone app's `SpotlightIndexer`; no extension indexes.
enum SpotlightPlan {
    static let titleLimit = 80
    static let summaryLimit = 300
    /// The most text read from a clip, so a multi-MB clip is never scanned whole.
    static let textPrefix = 1000

    struct Input: Sendable {
        let id: UUID
        let contentType: ContentType
        /// At most `textPrefix` characters.
        let text: String?
        let ocrText: String?
        let linkTitle: String?
        let fileNames: [String]
        /// An image's thumbnail, or a link's page image.
        let hasThumbnail: Bool
        let isSensitive: Bool
    }

    /// The entry for `input`, or nil for anything never indexed: a secret, an image with no text read in it or whose text
    /// is a secret, a color, an unknown type, empty text. `bundle` holds the catalog; tests pass one language's `.lproj`.
    static func record(for input: Input, bundle: Bundle = .main) -> SpotlightRecord? {
        guard !input.isSensitive else { return nil }
        let id = input.id
        switch input.contentType {
        case .plainText, .richText, .html:
            guard let text = clean(input.text) else { return nil }
            let (title, summary) = split(text, room: titleLimit)
            return SpotlightRecord(id: id, title: title, summary: summary, thumbnailSource: .none)
        case .url:
            guard let url = clean(input.text) else { return nil }
            let thumbnail: SpotlightRecord.ThumbnailSource = input.hasThumbnail ? .link : .none
            guard let page = clean(input.linkTitle) else {
                return SpotlightRecord(id: id, title: String(url.prefix(titleLimit)), summary: "", thumbnailSource: thumbnail)
            }
            return SpotlightRecord(id: id, title: split(page, room: titleLimit).title,
                                   summary: String(url.prefix(summaryLimit)), thumbnailSource: thumbnail)
        case .image:
            // The text read is an image's only text, so an image that reads as a secret stays out, whatever "Protect
            // secrets" says: Spotlight is outside the app, where nothing can be masked.
            guard let text = clean(input.ocrText), SecretDetector.kind(of: text) == nil else { return nil }
            let label = String(localized: "Image", bundle: bundle) + " \u{00b7} "
            let (line, summary) = split(text, room: titleLimit - label.count)
            return SpotlightRecord(id: id, title: label + line, summary: summary,
                                   thumbnailSource: input.hasThumbnail ? .image : .none)
        case .files:
            let names = input.fileNames.compactMap(clean)
            guard let first = names.first else { return nil }
            return SpotlightRecord(id: id, title: String(first.prefix(titleLimit)),
                                   summary: String(names.dropFirst().joined(separator: ", ").prefix(summaryLimit)),
                                   thumbnailSource: .none)
        // `fileURL` is a Mac's local path: it never syncs, and the iPhone's history hides it.
        case .fileURL, .color, .unknown:
            return nil
        }
    }

    /// The entries to add or refresh, and the ids to remove. A saved clip with no entry (made a secret, its text gone)
    /// is removed; a delete wins over a save of the same id.
    static func changes(saved: [Input], deleted: [UUID]) -> (upsert: [SpotlightRecord], delete: [UUID]) {
        let gone = Set(deleted)
        var upsert: [SpotlightRecord] = [], delete = deleted
        for input in saved where !gone.contains(input.id) {
            if let record = record(for: input) { upsert.append(record) } else { delete.append(input.id) }
        }
        return (upsert, delete)
    }

    private static func clean(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// The first line, at most `room` characters, and what follows it, at most `summaryLimit`. A line too long for the
    /// title goes on in the summary.
    private static func split(_ text: String, room: Int) -> (title: String, summary: String) {
        let title = String(text.prefix { !$0.isNewline }.prefix(room))
        let rest = text.dropFirst(title.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, String(rest.prefix(summaryLimit)))
    }

    /// The records Spotlight holds as this launch indexed them, so a save that changes nothing Spotlight shows (sync
    /// bookkeeping, a pin) is not indexed again. Kept in memory only: after a launch, each clip's first save reindexes it.
    final class IndexedRecords: Sendable {
        private let records = OSAllocatedUnfairLock(initialState: [UUID: SpotlightRecord]())

        /// `upsert` without the records already indexed exactly so.
        func changed(_ upsert: [SpotlightRecord]) -> [SpotlightRecord] {
            records.withLock { held in upsert.filter { held[$0.id] != $0 } }
        }

        /// Call once Spotlight has taken `indexed`.
        func stored(_ indexed: [SpotlightRecord]) {
            records.withLock { held in for record in indexed { held[record.id] = record } }
        }

        func removed(_ ids: [UUID]) {
            records.withLock { held in for id in ids { held[id] = nil } }
        }

        func removeAll() {
            records.withLock { $0 = [:] }
        }
    }

    /// Whether the index is in step with the store across the indexer's queued jobs. The stored index version is cleared
    /// when the first job is queued, and stored again only once the queue drains with no job lost since the last full
    /// rebuild or clear. A launch that finds it missing, after a kill or a failed job, rebuilds.
    struct JobLedger {
        private var running = 0
        private var lost = false

        /// A job was queued. True: clear the stored version now.
        mutating func start() -> Bool {
            running += 1
            return running == 1
        }

        /// A job ended. `resets`: a rebuild or a clear, which brings the index in step on its own. True: store the version.
        mutating func finish(succeeded: Bool, resets: Bool) -> Bool {
            running -= 1
            if !succeeded { lost = true } else if resets { lost = false }
            return running == 0 && !lost
        }
    }

    /// Hands over the clip ids each save of `context` touched: collected at `willSave`, while a deleted clip's id can
    /// still be read, and passed on at `didSave`, once the save landed. A failed save posts no `didSave` and keeps its
    /// changes, so the next `willSave` collects them again. Relies on both being posted on the saving (main) thread,
    /// as `LocalChangeTracker` does.
    @MainActor final class SaveObserver {
        private let context: ModelContext
        private let onSave: @MainActor (_ saved: Set<UUID>, _ deleted: Set<UUID>) -> Void
        private var saved: Set<UUID> = [], deleted: Set<UUID> = []
        nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []  // only touched in init and deinit

        init(context: ModelContext, onSave: @escaping @MainActor (_ saved: Set<UUID>, _ deleted: Set<UUID>) -> Void) {
            self.context = context
            self.onSave = onSave
            let center = NotificationCenter.default
            tokens = [
                center.addObserver(forName: ModelContext.willSave, object: context, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.collect() }
                },
                center.addObserver(forName: ModelContext.didSave, object: context, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handOver() }
                },
            ]
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }

        private func collect() {
            saved = []
            deleted = []
            for case let clip as ClipboardItem in context.deletedModelsArray { deleted.insert(clip.id) }
            for case let clip as ClipboardItem in context.insertedModelsArray + context.changedModelsArray {
                saved.insert(clip.id)
            }
        }

        private func handOver() {
            let saved = saved.subtracting(deleted), deleted = deleted
            self.saved = []
            self.deleted = []
            if !saved.isEmpty || !deleted.isEmpty { onSave(saved, deleted) }
        }
    }
}

struct SpotlightRecord: Equatable, Sendable {
    enum ThumbnailSource: Equatable, Sendable { case image, link, none }
    let id: UUID
    /// At most `SpotlightPlan.titleLimit` characters.
    let title: String
    /// At most `SpotlightPlan.summaryLimit` characters.
    let summary: String
    let thumbnailSource: ThumbnailSource
}

extension SpotlightPlan.Input {
    /// `linkPreviews`: "Link previews" is on. Off, a link shows as its URL, as on the cards.
    init(_ clip: ClipboardItem, linkPreviews: Bool) {
        let isLink = clip.contentType == .url
        self.init(id: clip.id, contentType: clip.contentType,
                  text: clip.textContent.map { String($0.prefix(SpotlightPlan.textPrefix)) },
                  ocrText: clip.ocrText.map { String($0.prefix(SpotlightPlan.textPrefix)) },
                  linkTitle: linkPreviews ? clip.linkTitle : nil,
                  fileNames: clip.fileManifest?.map(\.name) ?? [],
                  hasThumbnail: isLink ? linkPreviews && clip.linkImageData != nil : clip.thumbnailData != nil,
                  isSensitive: clip.isSensitive)
    }
}
