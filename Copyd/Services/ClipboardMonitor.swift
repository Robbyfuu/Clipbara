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
    /// A copy is being prepared off the main thread.
    @ObservationIgnored private var isCapturing = false
    /// Gets the id of every clip the user copies, including a recent duplicate that is not saved
    /// again (its existing id), so Paste Stack can queue it. Copyd's own pastes are skipped before this.
    @ObservationIgnored var onCapture: ((UUID) -> Void)?
    /// Called before Copyd writes clips picked in its own UI, with their ids. Every pick goes through `skipNextChange`.
    @ObservationIgnored var onPick: (([UUID]) -> Void)?

    var isMonitoring: Bool = false
    var latestItems: [ClipboardItem] = []
    var historyLimit: Int {
        get { UserDefaults.standard.object(forKey: "historyLimit") as? Int ?? 500 }
        set { UserDefaults.standard.set(newValue, forKey: "historyLimit") }
    }

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        lastChangeCount = NSPasteboard.general.changeCount
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

        if shouldSkipNextChange {
            shouldSkipNextChange = false
            return
        }

        // Check excluded apps
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontApp.bundleIdentifier,
           excludedBundleIds.contains(bundleId) {
            return
        }

        guard let content = classifier.classify(pasteboard) else { return }
        let sourceApp = NSWorkspace.shared.frontmostApplication
        let source = (name: sourceApp?.localizedName, bundleId: sourceApp?.bundleIdentifier)

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
        cleanupOldItems()
        refreshLatestItems()
        onCapture?(item.id)
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

    /// Paste Stack staging its next clip: not captured, and not a pick.
    func skipStagedChange() {
        shouldSkipNextChange = true
    }

    func loadExcludedApps() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ExcludedApp>()
        let apps = (try? modelContext.fetch(descriptor)) ?? []
        excludedBundleIds = Set(apps.map(\.bundleId))
    }
}
