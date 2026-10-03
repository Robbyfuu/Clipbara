import SwiftUI
import SwiftData
import UIKit
import OSLog

/// Owns the shared store and the sync engine for the iOS app.
@MainActor @Observable
final class AppModel {
    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "AppModel")

    let container: ModelContainer
    let sync: CloudSyncEngine
    /// True when the App Group container was unavailable and the store lives in memory only.
    let isInMemory: Bool
    var toastVisible = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init() {
        UserDefaults.standard.register(defaults: [CloudSyncEngine.enabledDefaultsKey: true])
        let schema = Schema([ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self])
        var inMemory = false
        let configuration: ModelConfiguration
        if let group = SharedStore.groupContainer {
            configuration = ModelConfiguration(schema: schema, url: SharedStore.url(groupContainer: group), cloudKitDatabase: .none)
        } else {
            Self.log.error("App Group container unavailable, using an in-memory store")
            inMemory = true
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        }
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Could not create the store: \(error)")
        }
        isInMemory = inMemory
        #if DEBUG
        Self.seedSampleClipsIfRequested(container)
        Self.removeSeedClipsUnlessSeeding(container)
        #endif
        sync = CloudSyncEngine(container: container) {}
        if UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) { sync.start() }
    }

    /// Copies the clip to the pasteboard and flashes the "Copied" toast.
    /// Returns false, with no toast, when there was nothing to write.
    @discardableResult
    func copy(_ item: ClipboardItem) -> Bool {
        switch item.contentType {
        case .image:
            guard let image = PasteboardImage.payload(from: item.rawData, maxPixels: 4096) else { return false }
            UIPasteboard.general.setData(image.data, forPasteboardType: image.uti)
        default:
            guard let text = item.textContent, !text.isEmpty else { return false }
            UIPasteboard.general.string = text
        }
        toastTask?.cancel()
        toastVisible = true
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { toastVisible = false }
        }
        return true
    }

    #if DEBUG
    /// `-CopydSeedSampleClips`: inserts 3 sample clips when the store is nearly empty.
    /// Refuses to run unless sync is off (`-iCloudSyncEnabled NO`), so samples never reach iCloud.
    /// Without `-CopydSeedSampleClips`, deletes leftover `seed-*` rows. Runs before the sync engine exists,
    /// so no tracker sees the delete and `queueEverything` never uploads the samples.
    private static func removeSeedClipsUnlessSeeding(_ container: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: "CopydSeedSampleClips") else { return }
        let context = ModelContext(container)
        let seeds = (try? context.fetch(FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.contentHash.starts(with: "seed-") }))) ?? []
        guard !seeds.isEmpty else { return }
        seeds.forEach(context.delete)
        try? context.save()
    }

    private static func seedSampleClipsIfRequested(_ container: ModelContainer) {
        guard UserDefaults.standard.bool(forKey: "CopydSeedSampleClips"),
              !UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) else { return }
        let context = ModelContext(container)
        guard ((try? context.fetchCount(FetchDescriptor<ClipboardItem>())) ?? 0) < 3 else { return }
        let long = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 5)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400))
        let png = renderer.pngData { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            UIColor.systemYellow.setFill(); ctx.fill(CGRect(x: 150, y: 100, width: 300, height: 200))
        }
        context.insert(ClipboardItem(contentType: .plainText, rawData: Data("Hello from Copyd".utf8),
                                     textContent: "Hello from Copyd", contentHash: "seed-short"))
        context.insert(ClipboardItem(contentType: .plainText, rawData: Data(long.utf8),
                                     textContent: long, contentHash: "seed-long"))
        context.insert(ClipboardItem(contentType: .image, rawData: png, thumbnailData: Thumbnail.png(from: png),
                                     contentHash: "seed-image"))
        try? context.save()
    }
    #endif
}
