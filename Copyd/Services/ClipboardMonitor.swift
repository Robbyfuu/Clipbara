import AppKit
import SwiftData

@MainActor
@Observable
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let classifier = ContentTypeClassifier()
    private var modelContext: ModelContext?
    private var excludedBundleIds: Set<String> = []
    private var shouldSkipNextChange: Bool = false
    /// The source of the next change instead of the frontmost app; consumed by it, captured or not.
    @ObservationIgnored private var nextSource: String?
    /// A copy is being prepared off the main thread.
    @ObservationIgnored private var isCapturing = false
    /// Gets the id of every clip the user copies, including a recent duplicate that is not saved
    /// again (its existing id), so Paste Stack can queue it. Copyd's own pastes are skipped before this.
    @ObservationIgnored var onCapture: ((UUID) -> Void)?
    /// Called before Copyd writes clips picked in its own UI, with their ids. Every pick goes through `skipNextChange`.
    @ObservationIgnored var onPick: (([UUID]) -> Void)?
    /// Called after a new image clip is saved, so its text is read right away.
    @ObservationIgnored var onNewImage: (() -> Void)?
    /// Called after a new link clip is saved, so its preview is fetched right away.
    @ObservationIgnored var onNewLink: (() -> Void)?
    /// Apps whose identity is rendering, so two quick copies from one app render it once.
    @ObservationIgnored private var publishing: Set<String> = []

    var isMonitoring: Bool = false
    var latestItems: [ClipboardItem] = []
    var historyLimit: Int {
        get { UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 500 }
        set { UserDefaults.standard.set(newValue, forKey: "historyLimit") }
    }

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        lastChangeCount = NSPasteboard.general.changeCount
        // Any change so far is passed over, so a skip or a source set while paused is spent: kept, it would hit the
        // first real copy after resuming.
        shouldSkipNextChange = false
        nextSource = nil
        loadExcludedApps()
        isMonitoring = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    func toggle() {
        if isMonitoring { stop() } else if let ctx = modelContext { start(modelContext: ctx) }
    }

    func refreshLatestItems() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.copiedAt, order: .reverse)]
        )
        var limited = descriptor
        limited.fetchLimit = 5
        latestItems = (try? modelContext.fetch(limited)) ?? []
    }

    private func poll() {
        // The last copy is still being read and hashed: the next change waits for it, so captures keep their order.
        guard !isCapturing else { return }
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount
        let attributed = nextSource
        nextSource = nil

        if shouldSkipNextChange {
            shouldSkipNextChange = false
            return
        }

        // Check excluded apps; not for an attributed write, which the frontmost app didn't make.
        if attributed == nil, let frontApp = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontApp.bundleIdentifier,
           excludedBundleIds.contains(bundleId) {
            return
        }

        guard let content = classifier.classify(pasteboard) else { return }
        let sourceApp = attributed == nil ? NSWorkspace.shared.frontmostApplication : nil
        let source = (name: attributed ?? sourceApp?.localizedName, bundleId: sourceApp?.bundleIdentifier)

        // Copied files (up to 48 MB), the hash and the thumbnail would stall the main thread: prepare them off it.
        isCapturing = true
        Task { [weak self] in
            let prepared = await Task.detached(priority: .userInitiated) {
                let content = content.readingFiles()
                return (content: content,
                        hash: ClipCapture.hash(content.rawData),
                        // Images, and file clips with an image file
                        thumbnail: Thumbnail.png(for: content.contentType, rawData: content.rawData),
                        // Names and sizes for the card, so it never reads the bundle.
                        manifest: content.contentType == .files ? FileBundle.manifestJSON(content.rawData) : nil)
            }.value
            self?.isCapturing = false
            self?.store(prepared.content, hash: prepared.hash, thumbnail: prepared.thumbnail, manifest: prepared.manifest,
                        sourceAppName: source.name, sourceAppBundleId: source.bundleId)
        }
    }

    /// Inserts a prepared copy, then tells Paste Stack, so it never queues a clip that isn't saved.
    private func store(_ content: ContentTypeClassifier.ClassifiedContent, hash: String, thumbnail: Data?, manifest: Data?,
                       sourceAppName: String?, sourceAppBundleId: String?) {
        // Duplicate check within last 10 seconds. Copying it again still counts for Paste Stack.
        if let existingID = recentDuplicateID(hash: hash) {
            onCapture?(existingID)
            return
        }

        let item = ClipboardItem(
            contentType: content.contentType,
            rawData: content.rawData,
            textContent: content.textContent,
            sourceAppName: sourceAppName,
            sourceAppBundleId: sourceAppBundleId,
            contentHash: hash
        )
        // The iPhone's own copy coming back: it syncs, but the iPhone never announces it.
        item.fromUniversalClipboard = content.fromUniversalClipboard
        item.thumbnailData = thumbnail
        item.fileManifestData = manifest
        // A key, token or card: kept on this Mac, masked, and deleted by SecretSweeper.
        item.isSensitive = SecretDetector.flags(content.textContent, type: content.contentType)

        modelContext?.insert(item)
        try? modelContext?.save()
        publishIdentity(bundleId: sourceAppBundleId, name: sourceAppName, isSensitive: item.isSensitive)
        cleanupOldItems()
        refreshLatestItems()
        onCapture?(item.id)
        if content.contentType == .image { onNewImage?() }
        if content.contentType == .url { onNewLink?() }
    }

    /// Publishes the source app's name, icon and color for the iPhone and other Macs (`AppIdentity`): once per app,
    /// again after 7 days, never for Copyd or a secret. Over the identity this Mac has for the app, synced or its own, so
    /// one Mac never adds a second record for it. The icon renders off the main thread; the save uploads through the
    /// tracker.
    private func publishIdentity(bundleId: String?, name: String?, isSensitive: Bool) {
        guard let bundleId, let modelContext, !publishing.contains(bundleId) else { return }
        let existing = try? AppIdentity.find(bundleId, in: modelContext)
        guard AppIdentityPublisher.needsPublish(existing: existing?.updatedAt, now: .now, bundleId: bundleId,
                                                ownBundleId: Bundle.main.bundleIdentifier ?? "",
                                                isSensitive: isSensitive) else { return }
        publishing.insert(bundleId)
        Task { [weak self] in
            let art = await Task.detached(priority: .utility) { AppIconProvider.identityArt(for: bundleId) }.value
            guard let self else { return }
            publishing.remove(bundleId)
            guard let art, let modelContext = self.modelContext else { return }
            let name = name ?? bundleId
            if let m = try? AppIdentity.find(bundleId, in: modelContext) {
                m.name = name
                m.iconPNG = art.png
                m.colorHex = art.color.hex
                m.updatedAt = .now
            } else {
                modelContext.insert(AppIdentity(bundleId: bundleId, name: name, iconPNG: art.png, colorHex: art.color.hex))
            }
            try? modelContext.save()
        }
    }

    /// 히스토리 제한 초과 시 오래된 아이템 삭제 (isPinned 아이템 보존)
    private func cleanupOldItems() {
        guard let modelContext, historyLimit > 0 else { return }

        let countDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned }
        )
        let unpinnedCount = (try? modelContext.fetchCount(countDescriptor)) ?? 0

        guard unpinnedCount > historyLimit else { return }

        let deleteCount = unpinnedCount - historyLimit
        var fetchDescriptor = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { !$0.isPinned },
            sortBy: [SortDescriptor(\.copiedAt, order: .forward)]
        )
        fetchDescriptor.fetchLimit = deleteCount

        guard let itemsToDelete = try? modelContext.fetch(fetchDescriptor) else { return }

        for item in itemsToDelete {
            // 연관 PinboardEntry 제거
            let itemId = item.id
            let entryDescriptor = FetchDescriptor<PinboardEntry>(
                predicate: #Predicate { $0.clipboardItem?.id == itemId }
            )
            if let entries = try? modelContext.fetch(entryDescriptor) {
                for entry in entries {
                    modelContext.delete(entry)
                }
            }
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func recentDuplicateID(hash: String) -> UUID? {
        guard let modelContext else { return nil }
        let tenSecondsAgo = Date().addingTimeInterval(-10)
        let predicate = #Predicate<ClipboardItem> { item in
            item.contentHash == hash && item.copiedAt > tenSecondsAgo
        }
        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.copiedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.id
    }

    /// Clips picked in Copyd's UI are about to be written: don't capture them, and tell `onPick`.
    func skipNextChange(picking ids: [UUID]) {
        onPick?(ids)
        shouldSkipNextChange = true
    }

    /// Paste Stack staging its next clip, or Settings copying the MCP token or a client config: not captured, and not a
    /// pick, so nothing pastes into the front app.
    func skipStagedChange() {
        shouldSkipNextChange = true
    }

    /// Copyd is about to write for an MCP client: the next change is captured as from `name`, with no app, instead of
    /// from the frontmost app.
    func attributeNextCapture(to name: String) {
        nextSource = name
    }

    func loadExcludedApps() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ExcludedApp>()
        let apps = (try? modelContext.fetch(descriptor)) ?? []
        excludedBundleIds = Set(apps.map(\.bundleId))
    }
}
