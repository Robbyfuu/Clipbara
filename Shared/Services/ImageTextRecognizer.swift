import Foundation
import SwiftData
import Vision

/// On-device text recognition with Vision. Compiled into the Mac and iPhone apps only: `project.yml` keeps it out of
/// the keyboard, widget and Share extensions, which never read images.
enum ImageTextRecognizer {
    /// The text in an image, one line per recognized line. Nil when there is none or the data is not an image.
    /// Reads a copy downsampled to `OCRPlan.targetPixelSize`, never the full image. Blocks: call it off the main actor.
    static func text(in data: Data) -> String? {
        guard let image = OCRPlan.downsampled(data) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["es", "en"]
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Fills `ocrText` for image clips, newest first, one `OCRPlan` batch at a time. The store is read and Vision runs in
/// detached utility tasks with their own `ModelContext`, so `rawData` never loads on the main actor. Results are
/// written on the main context, then `save` stores them without queueing an upload: the fields never sync.
@MainActor final class ImageTextQueue {
    private let container: ModelContainer
    private let save: @MainActor (Set<UUID>) -> Void
    /// The running pass. Never more than one: a `fill` meanwhile makes it go round once more.
    private(set) var task: Task<Void, Never>?
    private var again = false

    init(container: ModelContainer, save: @escaping @MainActor (Set<UUID>) -> Void) {
        self.container = container
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
        let container = container
        var last: [UUID] = []
        while !Task.isCancelled {
            let batch = await Task.detached(priority: .utility) { Self.nextBatch(in: container) }.value
            // The same batch again means the last write didn't land: stop rather than read it forever.
            guard !batch.isEmpty, batch != last else { return }
            last = batch
            var results: [(id: UUID, text: String?)] = []
            for id in batch {
                if Task.isCancelled { break }
                let text = await Task.detached(priority: .utility) { Self.text(of: id, in: container) }.value
                results.append((id, text))
            }
            write(results)
        }
    }

    /// Marks each clip read, with its text or none. A clip deleted meanwhile is skipped.
    private func write(_ results: [(id: UUID, text: String?)]) {
        guard !results.isEmpty else { return }
        let context = container.mainContext
        for result in results {
            guard let clip = context.syncClip(id: result.id), !clip.isGone else { continue }
            clip.ocrText = result.text
            clip.ocrDone = true
        }
        save(Set(results.map(\.id)))
    }

    nonisolated private static func nextBatch(in container: ModelContainer) -> [UUID] {
        let image = ContentType.image.rawValue
        var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentTypeRaw == image },
                                                   sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        fetch.fetchLimit = OCRPlan.window
        fetch.propertiesToFetch = [\.id, \.contentTypeRaw, \.ocrDone, \.copiedAt]
        let clips = (try? ModelContext(container).fetch(fetch)) ?? []
        return OCRPlan.nextBatch(clips: clips.map { ($0.id, $0.contentType == .image, $0.ocrDone, $0.copiedAt) })
    }

    nonisolated private static func text(of id: UUID, in container: ModelContainer) -> String? {
        var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 1
        guard let clip = try? ModelContext(container).fetch(fetch).first else { return nil }
        return ImageTextRecognizer.text(in: clip.rawData)
    }
}
