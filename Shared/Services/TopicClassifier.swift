import Foundation
import SwiftData
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Asks the on-device Apple Intelligence model (macOS 26+, iOS 26+) for a clip's topic. FoundationModels is weak-linked:
/// before 26, or with Apple Intelligence off, the model is unavailable and no topic board shows. Compiled into the Mac
/// and iPhone apps only: `project.yml` keeps it out of the extensions, which only read the result.
enum TopicClassifier {
    /// The longest one answer may take, a cold model load included, before the clip is left for the next fill.
    static let timeout: TimeInterval = 15

    /// Apple Intelligence is on and its model is ready: the pass runs. Always false before macOS 26 and iOS 26.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    /// Apple Intelligence is on, its model ready or still downloading: the topic boards and their setting show.
    static var isSupported: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) { return isSupported(SystemLanguageModel.default.availability) }
        #endif
        return false
    }

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    static func isSupported(_ availability: SystemLanguageModel.Availability) -> Bool {
        switch availability {
        case .available, .unavailable(.modelNotReady): true
        default: false
        }
    }
    #endif

    /// A failed request, as the clip stores it. What the same text would meet again is final with no topic (`other`):
    /// a guardrail, a refusal, an answer that never decodes, or a language the model doesn't read. Unsupported
    /// language when the device's own (`localeSupported` false) isn't supported, or missing assets, is `unavailable`.
    /// Anything else is retried. macOS and iOS 27 throw `LanguageModelError`; 26 throws `GenerationError`.
    static func outcome(for error: any Error, localeSupported: Bool) -> TopicPlan.Outcome {
        #if canImport(FoundationModels)
        if #available(macOS 27, iOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .guardrailViolation, .refusal: return .other
                case .unsupportedLanguageOrLocale: return localeSupported ? .other : .unavailable
                default: return .failed
                }
            }
            if case .assetsUnavailable = error as? SystemLanguageModel.Error { return .unavailable }
        }
        if #available(macOS 26, iOS 26, *), let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal, .decodingFailure: return .other
            case .unsupportedLanguageOrLocale: return localeSupported ? .other : .unavailable
            case .assetsUnavailable: return .unavailable
            default: return .failed
            }
        }
        #endif
        return .failed
    }

    /// One request in a fresh session: a session keeps every prompt in its transcript. Never call it with a secret's,
    /// an image's or a file's text: `TopicQueue` reads only what `TopicPlan.isEligible` lets through.
    static func classify(_ preview: String) async -> TopicPlan.Outcome {
        #if canImport(FoundationModels)
        guard #available(macOS 26, iOS 26, *) else { return .unavailable }
        guard isAvailable else { return .unavailable }
        let prompt = TopicPlan.prompt(previews: [preview])
        return await LinkPreviewFetcher.withDeadline(timeout) {
            do {
                let session = LanguageModelSession(instructions: TopicPlan.instructions)
                let topic = try await session.respond(to: prompt, generating: ClipTopic.self,
                                                      options: GenerationOptions(samplingMode: .greedy)).content
                return TopicPlan.outcome(topic.rawValue)
            } catch {
                return outcome(for: error, localeSupported: SystemLanguageModel.default.supportsLocale())
            }
        } ?? .failed
        #else
        return .unavailable
        #endif
    }
}

extension SmartBoard {
    /// The boards the Mac and iPhone list: the topic boards too, while "Group by topic" is on and Apple Intelligence is
    /// supported here. The keyboard lists the type boards only.
    static var listed: [SmartBoard] { TopicPlan.isEnabled && TopicClassifier.isSupported ? allCases : types }
}

#if canImport(FoundationModels)
/// The answer the model generates: a topic board's raw value, or `other`.
@available(macOS 26, iOS 26, *)
@Generable
enum ClipTopic: String {
    case work, shopping, travel, finance, study, social, personal, other
}
#endif

/// Asks the model about text and link clips, newest first, one `TopicPlan` batch at a time, the way `SmartKindsQueue`
/// sorts them. The store is read on a utility dispatch queue with its own `ModelContext`; the model runs off the main
/// actor. Results are written on the main context, then `save` stores them without queueing an upload: they never sync.
@MainActor final class TopicQueue {
    private let container: ModelContainer
    private let isEnabled: @MainActor () -> Bool
    /// The passes that run first (ruling R7): the type boards, and on the iPhone the image text too. Each pass waits for
    /// them to finish, so the model never runs beside them.
    private let waitsFor: @MainActor () -> [Task<Void, Never>?]
    /// `TopicPlan.shouldPause`, checked before each request and after each batch.
    private let shouldPause: @MainActor () -> Bool
    /// Between two batches.
    private let pause: Duration
    /// Holds `TopicPlan.versionDefaultsKey`.
    private let defaults: UserDefaults
    private let classify: @Sendable (String) async -> TopicPlan.Outcome
    private let save: @MainActor (Set<UUID>) -> Void
    /// The running pass. Never more than one: a `fill` meanwhile makes it go round once more.
    private(set) var task: Task<Void, Never>?
    private var again = false
    /// The model failed on these: left until the app comes back to the front, or the next launch, never retried on
    /// every capture.
    private var failed: Set<UUID> = []

    init(container: ModelContainer,
         isEnabled: @escaping @MainActor () -> Bool = { TopicPlan.isEnabled && TopicClassifier.isAvailable },
         waitsFor: @escaping @MainActor () -> [Task<Void, Never>?] = { [] },
         shouldPause: @escaping @MainActor () -> Bool = { TopicPlan.shouldPause() },
         pause: Duration = .seconds(2),
         defaults: UserDefaults = SecretDetector.settings,
         classify: @escaping @Sendable (String) async -> TopicPlan.Outcome = { await TopicClassifier.classify($0) },
         save: @escaping @MainActor (Set<UUID>) -> Void) {
        self.container = container
        self.isEnabled = isEnabled
        self.waitsFor = waitsFor
        self.shouldPause = shouldPause
        self.pause = pause
        self.defaults = defaults
        self.classify = classify
        self.save = save
    }

    /// Asks about the newest clips not asked yet: after a capture or an edit, at launch, after a sync, on return to the
    /// foreground. Nothing while either setting is off or the model is unavailable. `retryingFailures`: the app is
    /// active again, so the clips the model failed on are asked again too.
    func fill(retryingFailures: Bool = false) {
        if retryingFailures { failed = [] }
        guard isEnabled() else { return }
        again = true
        guard task == nil else { return }
        // Background work: the model runs at utility priority, below anything the user waits for.
        task = Task(priority: .utility) { [weak self] in await self?.drain() }
    }

    /// Ends the pass after the answer in flight, keeping what it already wrote.
    func stop() {
        again = false
        task?.cancel()
    }

    private func drain() async {
        while again, !Task.isCancelled {
            again = false
            for before in waitsFor() { await before?.value }
            if Task.isCancelled { break }
            await pass()
        }
        task = nil
        if again { fill() }  // a `fill` after `stop`, while the stopped pass was finishing
    }

    private func pass() async {
        guard !shouldPause() else { return }
        await resetIfStale()
        let container = container, classify = classify
        var last: [UUID] = []
        while !Task.isCancelled {
            let skipped = failed
            let batch = await ImageTextQueue.offMain { Self.nextBatch(in: container, skipping: skipped) }
            // The same batch again means the last write didn't land: stop rather than ask forever.
            guard !batch.isEmpty, batch.map(\.id) != last else { return }
            last = batch.map(\.id)
            var results: [Answered] = []
            for clip in batch {
                // Stopped, or paused (the panel opened, the device got hot): what was answered is kept.
                if Task.isCancelled || shouldPause() { return write(results) }
                let outcome = clip.preview.isEmpty ? .other : await classify(clip.preview)
                // Stopped meanwhile: the request may have been cut off, so its answer is not kept.
                if Task.isCancelled { return write(results) }
                // The model went away: this clip and every other stay unmarked until it is back.
                if outcome == .unavailable { return write(results) }
                guard outcome.isDone else { failed.insert(clip.id); continue }
                results.append(Answered(id: clip.id, contentHash: clip.contentHash, outcome: outcome))
            }
            write(results)
            if shouldPause() { return }
            // ponytail: a fixed pause between batches keeps the model off the CPU most of the time; make it follow the
            // load if a long backlog still feels heavy.
            try? await Task.sleep(for: pause)
        }
    }

    private struct Asked: Sendable {
        let id: UUID
        /// The content asked about, so an answer never lands on a clip edited meanwhile.
        let contentHash: String
        let preview: String
    }

    private struct Answered {
        let id: UUID
        let contentHash: String
        let outcome: TopicPlan.Outcome
    }

    /// Stores each answer and marks the clip done. Skips a clip deleted, edited or made a secret meanwhile.
    private func write(_ results: [Answered]) {
        let context = container.mainContext
        // A pending user change goes out in a save the tracker reports, before the save that hides these clips from it.
        if context.hasChanges { try? context.save() }
        guard !results.isEmpty else { return }
        let ids = results.map(\.id)
        let clips = (try? context.fetch(FetchDescriptor<ClipboardItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
        let byID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var written: Set<UUID> = []
        for result in results {
            guard let clip = byID[result.id], !clip.isGone, !clip.isSensitive,
                  clip.contentHash == result.contentHash else { continue }
            clip.topicRaw = result.outcome.topicRaw
            clip.topicDone = true
            written.insert(result.id)
        }
        if !written.isEmpty { save(written) }
    }

    /// Clips marked done with no topic under an older `TopicPlan.version` are asked again. Only the `TopicPlan.window`
    /// newest, the clips a pass reaches, found off the main thread.
    private func resetIfStale() async {
        guard defaults.integer(forKey: TopicPlan.versionDefaultsKey) != TopicPlan.version else { return }
        let container = container
        let ids = await ImageTextQueue.offMain { Self.staleIDs(in: container) }
        if !ids.isEmpty {
            let context = container.mainContext
            if context.hasChanges { try? context.save() }
            let stale = (try? context.fetch(FetchDescriptor<ClipboardItem>(predicate: #Predicate { ids.contains($0.id) }))) ?? []
            stale.forEach { $0.topicDone = false }
            if !stale.isEmpty { save(Set(stale.map(\.id))) }
        }
        defaults.set(TopicPlan.version, forKey: TopicPlan.versionDefaultsKey)
    }

    /// The window's clips marked done with no topic.
    nonisolated private static func staleIDs(in container: ModelContainer) -> [UUID] {
        var window = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        window.fetchLimit = TopicPlan.window
        window.propertiesToFetch = [\.id, \.topicDone, \.topicRaw]
        return ((try? ModelContext(container).fetch(window)) ?? []).filter { $0.topicDone && $0.topicRaw == nil }.map(\.id)
    }

    /// The next batch, with what the model reads of each. Only the batch's text is loaded: the window is read without
    /// it. The type and secret flag are checked again here, where the text is read, so the model never gets a clip
    /// that turned into a secret since the window was read.
    nonisolated private static func nextBatch(in container: ModelContainer, skipping failed: Set<UUID>) -> [Asked] {
        let context = ModelContext(container)
        var window = FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        window.fetchLimit = TopicPlan.window
        window.propertiesToFetch = [\.id, \.contentTypeRaw, \.isSensitive, \.topicDone, \.copiedAt, \.linkPreviewDone]
        let clips = (try? context.fetch(window)) ?? []
        let ids = TopicPlan.nextBatch(clips: clips.map {
            TopicPlan.Candidate(id: $0.id, contentType: $0.contentType, isSensitive: $0.isSensitive,
                                isDone: $0.topicDone, copiedAt: $0.copiedAt, linkPreviewDone: $0.linkPreviewDone)
        }, skipping: failed, waitsForLinkPreviews: LinkPreviewPlan.isEnabled, now: Date())
        guard !ids.isEmpty else { return [] }
        var batch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { ids.contains($0.id) })
        batch.propertiesToFetch = [\.id, \.contentTypeRaw, \.textContent, \.linkTitle, \.isSensitive, \.contentHash]
        let byID = Dictionary(((try? context.fetch(batch)) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in
            guard let clip = byID[id], TopicPlan.isEligible(clip.contentType, isSensitive: clip.isSensitive) else { return nil }
            return Asked(id: id, contentHash: clip.contentHash,
                         preview: TopicPlan.preview(text: clip.textContent, title: clip.linkPreviewTitle))
        }
    }
}
