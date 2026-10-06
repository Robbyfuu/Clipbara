import ActivityKit
import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import WidgetKit
import OSLog

/// Owns the shared store and the sync engine for the iOS app.
@MainActor @Observable
final class AppModel {
    private nonisolated static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "AppModel")
    /// The one instance. The scene delegate, which SwiftUI does not reach, hands it quick actions.
    static let shared = AppModel()

    let container: ModelContainer
    let sync: CloudSyncEngine
    /// Reads the text in image clips while the app is in the foreground only: started on launch and on every return,
    /// stopped when the app goes to the background.
    let imageText: ImageTextQueue
    /// Fetches link titles and images, foreground only like `imageText`.
    let linkPreviews: LinkPreviewQueue
    /// Keeps the clips in Spotlight, following every main-context save.
    let spotlight: SpotlightIndexer
    /// True when the App Group container was unavailable and the store lives in memory only.
    let isInMemory: Bool
    var toastVisible = false
    var toastText = String(localized: "Copied")
    /// A quick action or `copyd://` link the root view has not handled yet. Set before any view exists on a cold launch.
    var pendingRoute: QuickRoute?
    /// Each app's icon and header color, from the identities the Mac synced (`AppIdentity`), by bundle id.
    private(set) var appLooks: [String: AppLook] = [:]

    struct AppLook: Sendable {
        /// Decoded for a 28 pt row icon.
        let icon: UIImage
        let color: RGB?
    }
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var isDraining = false
    /// The last Live Activity change. Each waits for the one before, so an older state never lands last.
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var loggedActivitySize = false
    /// The last state built, reused while the newest clip and its copy time stay the same.
    @ObservationIgnored private var lastActivityState: LatestClipActivity.ContentState?

    /// Settings toggles, both off by default.
    static let liveActivityKey = "liveActivityEnabled"
    static let arrivalNotificationsKey = "arrivalNotificationsEnabled"

    private init() {
        UserDefaults.standard.register(defaults: [CloudSyncEngine.enabledDefaultsKey: true])
        // Shares a quit or crash left behind. Before any share can start, so none is removed mid-way.
        try? FileManager.default.removeItem(at: Self.shareDirectory)
        // Every save in the app refreshes the widget: Save Clipboard, Save Text, pin, unpin, delete, the seed,
        // and the sync engine's own saves. Any context, so the seed's separate context counts too.
        _ = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Self.reloadWidgets() }
        }
        let schema = Schema(StoreSchema.models)
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
        Self.seedOCRImageIfRequested(container)
        Self.seedLinkClipIfRequested(container)
        Self.seedSecretClipIfRequested(container)
        Self.seedCodeClipsIfRequested(container)
        Self.seedAppIdentityIfRequested(container)
        Self.removeSeedClipsUnlessSeeding(container)
        #endif
        // Before the engine starts, so the saves of its first fetch are indexed.
        spotlight = SpotlightIndexer(container: container)
        sync = CloudSyncEngine(container: container) { Self.remoteChangesApplied() }
        // The text read in an image never syncs, so its save queues no upload.
        imageText = ImageTextQueue(container: container) { [sync] ids in sync.saveLocalOnly(ids) }
        // Link previews never sync either.
        linkPreviews = LinkPreviewQueue(container: container) { [sync] ids in sync.saveLocalOnly(ids) }
        sync.onRemoteInserts = { [weak self] ids in self?.announceArrivals(ids) }
        sync.onMirrorWiped = { [weak self] in self?.spotlight.removeAll() }
        reloadAppLooks()
        if UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) { sync.start() }
        #if DEBUG
        Self.writeSampleInboxIfRequested()
        #endif
        // After the engine starts, so its tracker sees the inserts and uploads them.
        drainInbox()
        sweepSecrets()
        // Timers fire only while the app runs; the return to the foreground sweeps too.
        let sweepTimer = Timer.scheduledTimer(withTimeInterval: SecretSweeper.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sweepSecrets() }
        }
        sweepTimer.tolerance = SecretSweeper.tolerance
        #if DEBUG
        applyDebugRoute()
        spotlight.checkIfRequested()
        continueSpotlightIfRequested()
        #endif
        // Any save can change the newest clip: Save Clipboard, auto-capture, the inbox, Save Text, deletes, and the
        // sync engine's applied remote changes, foreground or a background push wake.
        _ = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLiveActivity() }
        }
    }

    /// Keeps the Lock Screen activity on the newest clip. Starts one when there is none, or when iOS ended the last
    /// after 8 hours; ends it when the setting is off or no clip is left. Only the foreground app may start an
    /// activity: a start from the background fails, and the next return to the foreground starts it.
    func updateLiveActivity() {
        let enabled = UserDefaults.standard.bool(forKey: Self.liveActivityKey)
        let state = enabled ? (try? LatestClip.newest(in: container.mainContext)).map {
            LatestClipActivity.ContentState.make(for: $0, reusing: lastActivityState)
        } : nil
        lastActivityState = state
        guard state != nil || !Activity<LatestClipActivity>.activities.isEmpty else { return }
        if let state, !loggedActivitySize {
            loggedActivitySize = true
            Self.log.notice("Live Activity state: \(state.encodedSize, privacy: .public) bytes")
        }
        let previous = activityTask
        activityTask = Task {
            await previous?.value
            await Self.show(state)
        }
    }

    /// Puts `state` in Copyd's one activity, or ends every activity when it is nil. Off the main actor: an `Activity`
    /// is not Sendable, so it never leaves this function.
    private nonisolated static func show(_ state: LatestClipActivity.ContentState?) async {
        let all = Activity<LatestClipActivity>.activities
        if let state, let live = all.first(where: { $0.activityState == .active || $0.activityState == .stale }) {
            if live.content.state != state { await live.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        // Off, no clip, or ended at 8 hours but still on screen: ended now, so a restart never shows two.
        for activity in all { await activity.end(nil, dismissalPolicy: .immediate) }
        if !all.isEmpty { log.notice("Live Activity ended (\(all.count, privacy: .public))") }
        // Live Activities turned off for Copyd in Settings: skip, the Settings card says so.
        guard let state, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(attributes: LatestClipActivity(), content: ActivityContent(state: state, staleDate: nil),
                                     pushType: nil)
            log.notice("Live Activity started")
        } catch {
            log.error("Live Activity not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes secrets past "Delete secrets after". The save's observers refresh the widget and the Live Activity.
    func sweepSecrets() {
        SecretSweeper.sweep(in: container.mainContext)
    }

    /// One notification for the clips a fetch brought, while Copyd is not on screen. Only the sync engine calls this,
    /// with remote inserts: local captures never reach it, nor the iPhone's own copies that the Mac captured from
    /// Universal Clipboard and synced back (`RemoteApplier.Outcome.arrivals` leaves them out).
    private func announceArrivals(_ ids: [UUID]) {
        guard UserDefaults.standard.bool(forKey: Self.arrivalNotificationsKey),
              UIApplication.shared.applicationState != .active else { return }
        // A remote clip is never a secret (the flag never syncs); the check keeps that true if it ever changes.
        let fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { ids.contains($0.id) && $0.isSensitive == false },
                                                   sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        guard let clips = try? container.mainContext.fetch(fetch), !clips.isEmpty else { return }
        let notice = ArrivalNotice.content(
            previews: clips.map { ArrivalNotice.preview(type: $0.contentType, text: $0.textContent) })
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Imports what the Share extension left in the inbox. Runs at launch and on every return to the foreground.
    /// The drain is synchronous on the main actor; the flag keeps a re-entrant call from importing an item twice.
    func drainInbox() {
        #if DEBUG
        // The sample is written now and imported by the next launch, as a real share would be.
        if UserDefaults.standard.bool(forKey: "CopydWriteSampleInbox") { return }
        #endif
        guard !isDraining, !isInMemory, let group = SharedStore.groupContainer else { return }
        isDraining = true
        defer { isDraining = false }
        let count = Inbox.drain(in: container.mainContext, directory: Inbox.directory(groupContainer: group), now: Date())
        guard count > 0 else { return }
        Self.reloadWidgets()
        flash("Added \(count) from Share")  // plural variation in the catalog
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
    /// Returns false, with no toast, when there was nothing to write, or the clip is gone (the sweep or a remote delete
    /// landed while a menu was open).
    /// - Parameter transformed: A "Copy as…" result, copied in place of the clip's own content.
    @discardableResult
    func copy(_ item: ClipboardItem, text transformed: String? = nil) -> Bool {
        guard !item.isGone else { return false }
        switch item.contentType {
        case .image where transformed == nil:
            guard let image = PasteboardImage.payload(from: item.rawData, maxPixels: 4096) else { return false }
            UIPasteboard.general.setData(image.data, forPasteboardType: image.uti)
        default:
            guard let text = transformed ?? item.textContent, !text.isEmpty else { return false }
            UIPasteboard.general.string = text
        }
        // Covers a row tap, the widget's `copy` route and Copy Latest Clip: all of them copy through here.
        PasteboardCapture.markHandled()
        flash("Copied")
        return true
    }

    /// Where `share` writes a file clip's files, one `<clip-id>` folder per share.
    private static let shareDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)

    /// A file clip's tap: writes its files to a temporary folder, removed when the share sheet closes,
    /// and opens the share sheet.
    func share(_ item: ClipboardItem) {
        let id = item.id, container = container
        let dir = Self.shareDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        Task {
            // Off the main actor, the rawData read included: a bundle holds up to 48 MB.
            let urls = try? await Task.detached {
                var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
                fetch.fetchLimit = 1
                guard let clip = try ModelContext(container).fetch(fetch).first else { return [URL]() }
                return try FileBundle.write(clip.rawData, to: dir)
            }.value
            guard let urls, !urls.isEmpty else { return flash("Couldn't share") }
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            // A Spotlight result opened on a cold launch may get here before the scene is active.
            let scene = scenes.first { $0.activationState == .foregroundActive }
                ?? scenes.first { $0.activationState == .foregroundInactive }
            var top = scene?.keyWindow?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            guard let top else {
                try? FileManager.default.removeItem(at: dir)
                return flash("Couldn't share")
            }
            let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
            // Done or cancelled, the activity has its copy by now.
            sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
            // iPad shows it as a popover: centered, with no arrow.
            sheet.popoverPresentationController?.sourceView = top.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            sheet.popoverPresentationController?.permittedArrowDirections = []
            top.present(sheet, animated: true)
        }
    }

    /// The widget's `copyd://copy/<uuid>` and a tapped Spotlight result: does what a tap on that clip's row does, so a
    /// file clip opens the share sheet instead of copying its file names.
    func copy(id: UUID) {
        var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        fetch.fetchLimit = 1
        // The clip may have been deleted since the widget last reloaded.
        guard let item = try? container.mainContext.fetch(fetch).first, !item.isGone else { return flash("Couldn't copy") }
        if item.contentType.sharesOnTap { return share(item) }
        if !copy(item) { flash("Couldn't copy") }
    }

    /// The widget shows the newest clips, so it reloads after every change to them. Copying changes nothing.
    /// A fetch brought changes: the widget reloads, and in the foreground the new images are read and the new links
    /// fetched. A background push wake does neither; the next return to the foreground does. Called by the engine after
    /// `shared` exists.
    private static func remoteChangesApplied() {
        reloadWidgets()
        shared.reloadAppLooks()
        guard UIApplication.shared.applicationState == .active else { return }
        shared.imageText.fill()
        shared.linkPreviews.fill()
    }

    /// Reads every identity and decodes its icon at 84 px (28 pt at 3x), all off the main thread. There is one per
    /// app the Mac copied from, so dozens at most.
    func reloadAppLooks() {
        let container = container
        Task {
            appLooks = await ImageTextQueue.offMain {
                let identities = (try? ModelContext(container).fetch(FetchDescriptor<AppIdentity>())) ?? []
                var looks: [String: AppLook] = [:]
                for m in identities {
                    guard let icon = Thumbnail.image(from: m.iconPNG, maxPixels: 84) else { continue }
                    looks[m.bundleId] = AppLook(icon: UIImage(cgImage: icon), color: RGB(hex: m.colorHex))
                }
                return looks
            }
        }
    }

    static func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Saves the iPhone pasteboard as a new clip, as the Mac's monitor would. Reading it shows iOS's paste prompt.
    /// The sync tracker uploads the insert like any other local save.
    func saveClipboard() {
        // The auto-capture or an earlier tap already read this copy; reading again would show a second paste prompt.
        guard UIPasteboard.general.changeCount != PasteboardCapture.lastReadCount else { return flash("Already saved") }
        // This copy is handled now, so the auto-capture never reads it (or asks to paste) again.
        PasteboardCapture.markHandled()
        // Types only, so no paste prompt. Matches the Mac, which skips password-manager and transient copies.
        guard !UIPasteboard.general.contains(pasteboardTypes: ClipCapture.skippedPasteboardTypes) else {
            return flash("Not saved: private copy")
        }
        guard let clip = PasteboardCapture.read() else { return flash("Clipboard is empty") }
        let context = container.mainContext
        // A failed check saves anyway: an extra row beats a lost clip.
        if (try? ClipCapture.isRecentDuplicate(hash: clip.contentHash, in: context, now: Date())) == true {
            return flash("Already saved")
        }
        insert(clip)
        flash("Saved")
    }

    /// Saves a copy made since Copyd last looked, each time the app opens. iOS lets only the foreground app read
    /// the pasteboard, so this is the app's whole auto-capture. Runs after `drainInbox`, so a copy the keyboard
    /// already queued is in history first. Content already anywhere in history is skipped silently.
    func captureNewCopy() {
        // A store in memory would lose the clip at quit, and the copy would be claimed. The Save Clipboard route
        // reads this copy itself; reading it here too would show the paste prompt twice.
        guard !isInMemory, pendingRoute != .saveClipboard, let clip = PasteboardCapture.newClip() else { return }
        // A failed check saves anyway: an extra row beats a lost clip.
        guard (try? ClipCapture.existsInHistory(hash: clip.contentHash, in: container.mainContext)) != true else { return }
        insert(clip)
        flash("Saved from clipboard")
    }

    /// Inserts and saves an iPhone copy. The save's observer reloads the widget; the sync tracker uploads it,
    /// unless it is a secret, which stays on this iPhone.
    private func insert(_ clip: CapturedClip) {
        let context = container.mainContext
        let thumbnail = clip.contentType == .image ? Thumbnail.png(from: clip.rawData) : nil
        let item = ClipboardItem(contentType: clip.contentType, rawData: clip.rawData, textContent: clip.textContent,
                                 thumbnailData: thumbnail, sourceAppName: UIDevice.current.model,
                                 contentHash: clip.contentHash)
        item.isSensitive = SecretDetector.flags(clip.textContent, type: clip.contentType)
        context.insert(item)
        try? context.save()
        // Only the foreground app reads the pasteboard, so this runs in the foreground.
        if item.contentType == .url { linkPreviews.fill() }
    }

    /// Shows `text` in the toast for 1.2 s and reads it to VoiceOver.
    private func flash(_ resource: LocalizedStringResource) {
        let text = String(localized: resource)
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
        guard !UserDefaults.standard.bool(forKey: "CopydSeedSampleClips"),
              !UserDefaults.standard.bool(forKey: "CopydSeedOCRImage"),
              !UserDefaults.standard.bool(forKey: "CopydSeedLinkClip"),
              !UserDefaults.standard.bool(forKey: "CopydSeedSecretClip"),
              !UserDefaults.standard.bool(forKey: "CopydSeedCodeClips"),
              !UserDefaults.standard.bool(forKey: "CopydSeedAppIdentity") else { return }
        let context = ModelContext(container)
        let seeds = (try? context.fetch(FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.contentHash.starts(with: "seed-") }))) ?? []
        let seedApp = seedAppBundleID
        let apps = (try? context.fetch(FetchDescriptor<AppIdentity>(predicate: #Predicate { $0.bundleId == seedApp }))) ?? []
        apps.forEach(context.delete)
        // Pinboards have no contentHash; the seed board is recognised by its fixed id. Deleting it cascades its entries.
        let seedBoardID = Self.seedBoardID
        let boards = (try? context.fetch(FetchDescriptor<Pinboard>(
            predicate: #Predicate { $0.id == seedBoardID }))) ?? []
        guard !seeds.isEmpty || !boards.isEmpty || !apps.isEmpty else { return }
        seeds.forEach(context.delete)
        boards.forEach(context.delete)
        try? context.save()
        invalidateSpotlight()
    }

    private static let seedBoardID = UUID(uuidString: "5EED0000-0000-4000-8000-000000000001")!
    private static let seedAppBundleID = "com.example.copyd-seed.atlas"

    /// `-CopydSeedAppIdentity YES`: inserts an app identity, as the Mac would sync it, and one clip copied from that
    /// app, for the row's icon and app color. Refuses to run unless sync is off (`-iCloudSyncEnabled NO`). A launch
    /// without any seed flag deletes both.
    private static func seedAppIdentityIfRequested(_ container: ModelContainer) {
        guard UserDefaults.standard.bool(forKey: "CopydSeedAppIdentity"),
              !UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) else { return }
        let context = ModelContext(container)
        guard (try? AppIdentity.find(seedAppBundleID, in: context)) == nil else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).pngData { ctx in
            UIColor(red: 0x2F / 255, green: 0x6B / 255, blue: 0xDB / 255, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 12, y: 12, width: 104, height: 104), cornerRadius: 24).fill()
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 40, y: 40, width: 48, height: 48))
        }
        context.insert(AppIdentity(bundleId: seedAppBundleID, name: "Atlas", iconPNG: icon, colorHex: "#2F6BDB"))
        let text = "Meet at the north entrance, 10:30"
        context.insert(ClipboardItem(contentType: .plainText, rawData: Data(text.utf8), textContent: text,
                                     sourceAppName: "Atlas", sourceAppBundleId: seedAppBundleID, contentHash: "seed-app"))
        try? context.save()
        invalidateSpotlight()
    }

    /// The seeds write through their own context, before the indexer exists, so it never sees them: dropping the stored
    /// index version makes it rebuild when it starts.
    private static func invalidateSpotlight() {
        SecretDetector.settings.removeObject(forKey: SpotlightIndexer.versionDefaultsKey)
    }

    /// `-CopydContinueSpotlight YES` (with `-CopydSeedSampleClips YES -iCloudSyncEnabled NO`): after 3 s, hands the
    /// scene's delegate a tapped Spotlight result for the "Hello from Copyd" sample, as iOS does while Copyd runs, then
    /// logs whether the pasteboard holds the clip.
    private func continueSpotlightIfRequested() {
        guard UserDefaults.standard.bool(forKey: "CopydContinueSpotlight") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentHash == "seed-short" })
            fetch.fetchLimit = 1
            guard let clip = try? container.mainContext.fetch(fetch).first,
                  let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive })
            else { return Self.log.error("Spotlight continue: no sample clip or no active scene") }
            let activity = NSUserActivity(activityType: QuickRoute.spotlightActivityType)
            activity.userInfo = [QuickRoute.spotlightIDKey: clip.id.uuidString]
            scene.delegate?.scene?(scene, continue: activity)
            try? await Task.sleep(for: .seconds(1))
            let copied = UIPasteboard.general.string == clip.textContent
            Self.log.notice("Spotlight continue \(copied ? "PASS" : "FAIL", privacy: .public): pasteboard holds the clip=\(copied, privacy: .public)")
        }
    }

    /// `-CopydWriteSampleInbox YES`: writes one text item to the inbox, as the Share extension would, and skips the
    /// drain for this launch. The next launch imports it and shows "Added 1 from Share".
    private static func writeSampleInboxIfRequested() {
        guard UserDefaults.standard.bool(forKey: "CopydWriteSampleInbox"), let group = SharedStore.groupContainer else { return }
        let item = InboxItem(kind: .text, text: "Shared from Safari: https://copyd.app/share", createdAt: Date())
        do { try Inbox.write(item, payload: nil, in: Inbox.directory(groupContainer: group)) } catch {
            log.error("Could not write the sample inbox item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `-CopydSeedOCRImage YES`: inserts one image reading "Copyd OCR test", not read yet, for the fill pass to find.
    /// Refuses to run unless sync is off (`-iCloudSyncEnabled NO`). A launch without either seed flag deletes it.
    private static func seedOCRImageIfRequested(_ container: ModelContainer) {
        guard UserDefaults.standard.bool(forKey: "CopydSeedOCRImage"),
              !UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) else { return }
        let context = ModelContext(container)
        let hash = "seed-ocr"
        guard ((try? context.fetchCount(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentHash == hash }))) ?? 0) == 0
        else { return }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 300)).pngData { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 300))
            ("Copyd OCR test" as NSString).draw(at: CGPoint(x: 40, y: 110), withAttributes: [
                .font: UIFont.systemFont(ofSize: 72, weight: .semibold), .foregroundColor: UIColor.black])
        }
        context.insert(ClipboardItem(contentType: .image, rawData: png, thumbnailData: Thumbnail.png(from: png), contentHash: hash))
        try? context.save()
        invalidateSpotlight()
    }

    /// `-CopydSeedLinkClip YES`: inserts one link to https://www.apple.com, not fetched yet, for the fill pass to find.
    /// Refuses to run unless sync is off (`-iCloudSyncEnabled NO`). A launch without any seed flag deletes it.
    private static func seedLinkClipIfRequested(_ container: ModelContainer) {
        guard UserDefaults.standard.bool(forKey: "CopydSeedLinkClip"),
              !UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) else { return }
        let context = ModelContext(container)
        let hash = "seed-preview-link"
        guard ((try? context.fetchCount(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentHash == hash }))) ?? 0) == 0
        else { return }
        let link = "https://www.apple.com"
        context.insert(ClipboardItem(contentType: .url, rawData: Data(link.utf8), textContent: link, contentHash: hash))
        try? context.save()
        invalidateSpotlight()
    }

    /// `-CopydSeedSecretClip YES`: inserts one secret, as a detected capture would, for the Spotlight check to miss.
    /// Refuses to run unless sync is off (`-iCloudSyncEnabled NO`). A launch without any seed flag deletes it.
    private static func seedSecretClipIfRequested(_ container: ModelContainer) {
        guard UserDefaults.standard.bool(forKey: "CopydSeedSecretClip"),
              !UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) else { return }
        let context = ModelContext(container)
        let hash = "seed-secret"
        guard ((try? context.fetchCount(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentHash == hash }))) ?? 0) == 0
        else { return }
        let secret = "sk" + "_live_" + "4eC39HqLyjWDarjtT1zdp7dc"  // split, so secret scanners skip this sample
        let clip = ClipboardItem(contentType: .plainText, rawData: Data(secret.utf8), textContent: secret, contentHash: hash)
        clip.isSensitive = true
        context.insert(clip)
        try? context.save()
        invalidateSpotlight()
    }

    /// `-CopydSeedCodeClips YES`: inserts one code clip and one color clip, for the code colors and the swatch row.
    /// Refuses to run unless sync is off (`-iCloudSyncEnabled NO`). A launch without any seed flag deletes them.
    private static func seedCodeClipsIfRequested(_ container: ModelContainer) {
        guard UserDefaults.standard.bool(forKey: "CopydSeedCodeClips"),
              !UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) else { return }
        let context = ModelContext(container)
        let hash = "seed-snippet"
        guard ((try? context.fetchCount(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentHash == hash }))) ?? 0) == 0
        else { return }
        let color = "#3478F6"
        context.insert(ClipboardItem(contentType: .color, rawData: Data(color.utf8), textContent: color, contentHash: "seed-swatch"))
        let code = "// Greets a user\nfunc greet(_ name: String) {\n    print(\"Hi, \\(name)!\", 42)\n}"
        context.insert(ClipboardItem(contentType: .plainText, rawData: Data(code.utf8), textContent: code, contentHash: hash))
        try? context.save()
        invalidateSpotlight()
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
        let bareItem = ClipboardItem(contentType: .plainText, rawData: Data(bareURL.utf8), textContent: bareURL,
                                     contentHash: "seed-bareurl")
        context.insert(bareItem)
        context.insert(ClipboardItem(contentType: .plainText, rawData: Data("464501".utf8), textContent: "464501",
                                     contentHash: "seed-code"))
        let work = Pinboard(name: "Work", displayOrder: 0)
        work.id = seedBoardID
        context.insert(work)
        for (order, item) in [short, bareItem].enumerated() {
            context.insert(PinboardEntry(clipboardItem: item, pinboard: work, displayOrder: order))
        }
        try? context.save()
        invalidateSpotlight()
    }
    #endif
}
