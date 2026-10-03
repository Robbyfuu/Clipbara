import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers
import OSLog

/// Owns the shared store and the sync engine for the iOS app.
@MainActor @Observable
final class AppModel {
    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "AppModel")
    /// The one instance. The scene delegate, which SwiftUI does not reach, hands it quick actions.
    static let shared = AppModel()

    let container: ModelContainer
    let sync: CloudSyncEngine
    /// True when the App Group container was unavailable and the store lives in memory only.
    let isInMemory: Bool
    var toastVisible = false
    var toastText = "Copied"
    /// A quick action or `copyd://` link the root view has not handled yet. Set before any view exists on a cold launch.
    var pendingRoute: QuickRoute?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private init() {
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
        #if DEBUG
        applyDebugRoute()
        #endif
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
        flash("Copied")
        return true
    }

    /// Saves the iPhone pasteboard as a new clip, as the Mac's monitor would. Reading it shows iOS's paste prompt.
    /// The sync tracker uploads the insert like any other local save.
    func saveClipboard() {
        // Types only, so no paste prompt. Matches the Mac, which skips password-manager and transient copies.
        guard !UIPasteboard.general.contains(pasteboardTypes: ClipCapture.skippedPasteboardTypes) else {
            return flash("Not saved: private copy")
        }
        guard let clip = Self.readPasteboard() else { return flash("Clipboard is empty") }
        let context = container.mainContext
        // A failed check saves anyway: an extra row beats a lost clip.
        if (try? ClipCapture.isRecentDuplicate(hash: clip.contentHash, in: context, now: Date())) == true {
            return flash("Already saved")
        }
        let thumbnail = clip.contentType == .image ? Thumbnail.png(from: clip.rawData) : nil
        context.insert(ClipboardItem(contentType: clip.contentType, rawData: clip.rawData, textContent: clip.textContent,
                                     thumbnailData: thumbnail, sourceAppName: UIDevice.current.model,
                                     contentHash: clip.contentHash))
        try? context.save()
        flash("Saved")
    }

    /// One read, so one paste prompt: an image (PNG first, else the first image type), otherwise the string.
    /// `hasImages` and `types` do not trigger the prompt.
    private static func readPasteboard() -> CapturedClip? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages else {
            return (pasteboard.string ?? pasteboard.url?.absoluteString).flatMap(ClipCapture.text)
        }
        let png = UTType.png.identifier
        let type = pasteboard.types.contains(png) ? png : pasteboard.types.first { UTType($0)?.conforms(to: .image) == true }
        return type.flatMap { pasteboard.data(forPasteboardType: $0) }.flatMap(ClipCapture.image)
    }

    /// Shows `text` in the toast for 1.2 s and reads it to VoiceOver.
    private func flash(_ text: String) {
        toastText = text
        toastTask?.cancel()
        toastVisible = true
        AccessibilityNotification.Announcement(text).post()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { toastVisible = false }
        }
    }

    #if DEBUG
    /// `-CopydOpenURL copyd://search`: sets `pendingRoute` before any view exists, as a cold-launch quick action does.
    /// With `-CopydOpenURLDelay 2`, opens the URL through the system after the delay instead, so it arrives by
    /// `onOpenURL` while the app runs. The simulator stops `simctl openurl` at a prompt that cannot be tapped headless.
    private func applyDebugRoute() {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: "CopydOpenURL").flatMap(URL.init(string:)),
              let route = QuickRoute(url: url) else { return }
        let delay = defaults.double(forKey: "CopydOpenURLDelay")
        guard delay > 0 else { return pendingRoute = route }
        Task {
            try? await Task.sleep(for: .seconds(delay))
            _ = await UIApplication.shared.open(url)
        }
    }

    /// `-CopydSeedSampleClips`: inserts 7 sample clips (one per card type) when the store is nearly empty.
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
        let bareURL = "https://www.airbnb.cl/rooms/1289209668570226847?check_in=2026-10-07"
        context.insert(ClipboardItem(contentType: .plainText, rawData: Data(bareURL.utf8), textContent: bareURL,
                                     contentHash: "seed-bareurl"))
        context.insert(ClipboardItem(contentType: .plainText, rawData: Data("464501".utf8), textContent: "464501",
                                     contentHash: "seed-code"))
        try? context.save()
    }
    #endif
}
