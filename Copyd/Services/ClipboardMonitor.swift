import AppKit
import SwiftData
import CryptoKit

@MainActor
@Observable
final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    private let classifier = ContentTypeClassifier()
    private var modelContext: ModelContext?
    private var excludedBundleIds: Set<String> = []
    private var shouldSkipNextChange: Bool = false
    /// Gets the id of every clip the user copies, including a recent duplicate that is not saved
    /// again (its existing id), so Paste Stack can queue it. Copyd's own pastes are skipped before this.
    @ObservationIgnored var onCapture: ((UUID) -> Void)?
    /// Called before Copyd writes a clip picked in its own UI. Every pick goes through `skipNextChange`.
    @ObservationIgnored var onPick: (() -> Void)?

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

        let hash = SHA256.hash(data: content.rawData)
            .compactMap { String(format: "%02x", $0) }
            .joined()

        // Duplicate check within last 10 seconds. Copying it again still counts for Paste Stack.
        if let existingID = recentDuplicateID(hash: hash) {
            onCapture?(existingID)
            return
        }

        let sourceApp = NSWorkspace.shared.frontmostApplication
        let item = ClipboardItem(
            contentType: content.contentType,
            rawData: content.rawData,
            textContent: content.textContent,
            sourceAppName: sourceApp?.localizedName,
            sourceAppBundleId: sourceApp?.bundleIdentifier,
            contentHash: hash
        )

        // Generate thumbnail for images
        if content.contentType == .image {
            item.thumbnailData = Thumbnail.png(from: content.rawData)
        }

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

    /// A clip picked in Copyd's UI is about to be written: don't capture it, and tell `onPick`.
    func skipNextChange() {
        onPick?()
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
