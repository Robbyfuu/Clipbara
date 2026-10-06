import Foundation
import SwiftData
import Vision

/// On-device text recognition with Vision. Compiled into the Mac and iPhone apps only: `project.yml` keeps it out of
/// the keyboard, widget and Share extensions, which never read images.
enum ImageTextRecognizer {
    /// `text` is a finished read: the text, or nil when there is none or the data is not an image. `failed` is a Vision
    /// error, worth another try later.
    enum Outcome: Equatable, Sendable {
        case text(String?)
        case failed
    }

    /// The text in an image, one line per recognized line. Reads a copy downsampled to `OCRPlan.targetPixelSize`, never
    /// the full image. Blocks, for as long as a cold Vision start takes: call it on a utility dispatch queue.
    static func text(in data: Data) -> Outcome {
        guard let image = OCRPlan.downsampled(data) else { return .text(nil) }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["es", "en"]
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return .failed }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return .text(text.isEmpty ? nil : text)
    }
}

/// Fills `ocrText` for image clips, newest first, one `OCRPlan` batch at a time. The store is read and Vision runs on a
/// utility dispatch queue, never the main actor nor the cooperative pool, each read with its own `ModelContext`, so
/// `rawData` never loads on the main actor. Results are written on the main context, then `save` stores them without
/// queueing an upload: the fields never sync.
@MainActor final class ImageTextQueue {
    private let container: ModelContainer
    private let recognize: @Sendable (Data) -> ImageTextRecognizer.Outcome
    private let save: @MainActor (Set<UUID>) -> Void
    /// The running pass. Never more than one: a `fill` meanwhile makes it go round once more.
    private(set) var task: Task<Void, Never>?
    private var again = false

    init(container: ModelContainer,
         recognize: @escaping @Sendable (Data) -> ImageTextRecognizer.Outcome = { ImageTextRecognizer.text(in: $0) },
         save: @escaping @MainActor (Set<UUID>) -> Void) {
        self.container = container
        self.recognize = recognize
        self.save = save
    }

    /// Reads the newest image clips not read yet: after a capture, at launch, on return to the foreground.
    func fill() {
        again = true
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    /// Ends the pass after the image being read, keeping what it already read. A stopped pass still finishes that image
    /// before `fill` can start the next, so two passes never overlap.
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
        let container = container, recognize = recognize
        var last: [UUID] = []
        // Vision errors in this pass: left unread for the next `fill`, never retried batch after batch.
        var failed: Set<UUID> = []
        while !Task.isCancelled {
            let skipped = failed
            let batch = await Self.offMain { Self.nextBatch(in: container, skipping: skipped) }
            // The same batch again means the last write didn't land: stop rather than read it forever.
            guard !batch.isEmpty, batch != last else { return }
            last = batch
            var results: [(id: UUID, text: String?)] = []
            for id in batch {
                if Task.isCancelled { break }
                switch await Self.offMain({ Self.read(id, in: container, with: recognize) }) {
                case .text(let text): results.append((id, text))
                case .failed: failed.insert(id)
                }
            }
            write(results)
        }
    }

    /// Runs `work` on a utility dispatch queue: a cold Vision start can block for a minute, and must never hold one of
    /// the cooperative pool's few threads. `LinkPreviewQueue` reads the store and decodes images through it too.
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }

    /// Marks each clip read, with its text or none. A clip deleted meanwhile is skipped.
    private func write(_ results: [(id: UUID, text: String?)]) {
        let context = container.mainContext
        // A pending user change goes out in a save the tracker reports, before the save that hides these clips from it.
        if context.hasChanges { try? context.save() }
        guard !results.isEmpty else { return }
        for result in results {
            guard let clip = context.syncClip(id: result.id), !clip.isGone else { continue }
            clip.ocrText = result.text
            clip.ocrDone = true
        }
        save(Set(results.map(\.id)))
    }

    nonisolated private static func nextBatch(in container: ModelContainer, skipping failed: Set<UUID>) -> [UUID] {
        let image = ContentType.image.rawValue
        var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentTypeRaw == image },
                                                   sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        fetch.fetchLimit = OCRPlan.window
        fetch.propertiesToFetch = [\.id, \.contentTypeRaw, \.ocrDone, \.copiedAt]
        let context = ModelContext(container)
        let clips = (try? context.fetch(fetch)) ?? []
        return OCRPlan.nextBatch(clips: clips.map {
            ($0.id, $0.contentType == .image, $0.ocrDone || failed.contains($0.id), $0.copiedAt)
        })
    }

    nonisolated private static func read(_ id: UUID, in container: ModelContainer,
                                         with recognize: @Sendable (Data) -> ImageTextRecognizer.Outcome) -> ImageTextRecognizer.Outcome {
        var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 1
        // Bound for the whole read: `rawData` is external storage, loaded from this context when read.
        let context = ModelContext(container)
        guard let found = try? context.fetch(fetch) else { return .failed }
        guard let clip = found.first else { return .text(nil) }  // deleted meanwhile: `write` skips it
        return recognize(clip.rawData)
    }
}
