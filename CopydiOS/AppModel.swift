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
        container = Self.openStore(schema: schema, configuration: configuration, inMemory: &inMemory)
        isInMemory = inMemory
        #if DEBUG
        Self.seedSampleClipsIfRequested(container)
        Self.removeSeedClipsUnlessSeeding(container)
        #endif
        sync = CloudSyncEngine(container: container) {}
        if UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) { sync.start() }
    }

    /// The phone only mirrors iCloud, so a store that won't open is deleted with its sync state and downloaded again,
    /// as the Mac does. A second failure falls back to memory so the app still launches.
    private static func openStore(schema: Schema, configuration: ModelConfiguration, inMemory: inout Bool) -> ModelContainer {
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            log.error("Could not open the store: \(error.localizedDescription, privacy: .public)")
        }
        if !configuration.isStoredInMemoryOnly {
            let dir = configuration.url.deletingLastPathComponent()
            let name = configuration.url.lastPathComponent
            for file in [name, name + "-shm", name + "-wal", "SyncState.data"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                log.error("Store recovery failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        log.error("Using an in-memory store")
        inMemory = true
        do {
            return try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        } catch {
            fatalError("Cannot create any store: \(error)")
        }
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
    /// `-CopydSeedSampleClips`: inserts 5 sample clips (one per card type) when the store is nearly empty.
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
        let short = ClipboardItem(contentType: .plainText, rawData: Data("Hello from Copyd".utf8),
                                  textContent: "Hello from Copyd", contentHash: "seed-short")
        short.isPinned = true
        context.insert(short)
        let link = "https://www.airbnb.cl/rooms/39393838?check_in=2026-10-07&adults=3"
        context.insert(ClipboardItem(contentType: .url, rawData: Data(link.utf8), textContent: link, contentHash: "seed-link"))
        context.insert(ClipboardItem(contentType: .color, rawData: Data("#F8D14F".utf8), textContent: "#F8D14F",
                                     contentHash: "seed-color"))
        context.insert(ClipboardItem(contentType: .plainText, rawData: Data(long.utf8),
                                     textContent: long, contentHash: "seed-long"))
        context.insert(ClipboardItem(contentType: .image, rawData: png, thumbnailData: Thumbnail.png(from: png),
                                     contentHash: "seed-image"))
        try? context.save()
    }
    #endif
}
