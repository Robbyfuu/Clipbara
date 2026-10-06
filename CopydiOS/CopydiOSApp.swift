import SwiftUI
import SwiftData
import UIKit
import UserNotifications

/// CKSyncEngine registers its own subscription and handles the push; this only completes the callback.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set at launch, so a tap that cold-launches the app still reaches `didReceive`.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// The arrival notice is Copyd's only notification: a tap opens History.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { AppModel.shared.pendingRoute = .history }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        .newData
    }

    /// The SwiftUI `App` lifecycle only delivers Home Screen quick actions to a scene delegate.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

/// Hands Home Screen quick actions and tapped Spotlight results to `AppModel.pendingRoute`. SwiftUI's `WindowGroup`
/// still owns the window, so this never creates one.
@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch: the item or the Spotlight result arrives with the connection options, before any view exists.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { route(item) }
        for activity in connectionOptions.userActivities { route(activity) }
    }

    /// A Spotlight result tapped while Copyd runs, in the foreground or the background.
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        route(userActivity)
    }

    /// A tapped Spotlight result copies its clip, as a widget row does. The only route here, so nothing copies twice.
    private func route(_ activity: NSUserActivity) {
        if let route = QuickRoute(activityType: activity.activityType, userInfo: activity.userInfo) {
            AppModel.shared.pendingRoute = route
        }
    }

    /// Warm launch: the app was already running.
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(route(shortcutItem))
    }

    @discardableResult
    private func route(_ item: UIApplicationShortcutItem) -> Bool {
        guard let route = QuickRoute(shortcutType: item.type) else { return false }
        AppModel.shared.pendingRoute = route
        return true
    }
}

@main
struct CopydiOSApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    private let model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var tab = UserDefaults.standard.string(forKey: "CopydInitialTab") ?? "history"
    #else
    @State private var tab = "history"
    #endif
    @State private var focusSearch = false

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                HistoryView(focusSearch: $focusSearch) { tab = "settings" }
                    .tabItem { Label("History", systemImage: "clock") }.tag("history")
                PinboardsView().tabItem { Label("Pinboards", systemImage: "pin") }.tag("pinboards")
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
            }
            .tint(DesignTokens.Brand.ink)
            .overlay(alignment: .bottom) { CopiedToast(text: model.toastText, visible: model.toastVisible) }
            #if DEBUG
            .overlay(alignment: .bottom) { KeyboardPreviewHarness(container: model.container) }
            .overlay { WidgetPreviewHarness(container: model.container) }
            .overlay { SharePreviewHarness() }
            .overlay { LiveActivityPreviewHarness(container: model.container) }
            #endif
            .environment(model)
            .modelContainer(model.container)
            // fetchIfStale is a no-op when sync is off (no engine) and throttles itself to 30 s.
            // `initial`, so a cold launch captures the clipboard too. A repeat is harmless: the drain is idempotent
            // and the capture reads each `changeCount` once.
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Reading images and fetching links run in the foreground only; they pick up where they stopped on the
                // next return.
                if phase == .background {
                    model.imageText.stop()
                    model.linkPreviews.stop()
                    model.smartKinds.stop()
                }
                guard phase == .active else { return }
                model.drainInbox()
                model.captureNewCopy()
                model.sweepSecrets()
                model.sync.fetchIfStale()
                // After the drain and the capture, so their new images are read first.
                model.imageText.fill()
                model.linkPreviews.fill()
                model.smartKinds.fill()
                // Restarts the activity iOS ended after 8 hours; the saves above already updated a running one.
                model.updateLiveActivity()
            }
            .onOpenURL { url in
                // A link that only foregrounds the app still runs auto-capture behind the iOS prompt.
                // A link must never read the pasteboard: only the quick action and the intents may save the clipboard.
                if let route = QuickRoute(url: url), QuickRoute.allowsURL(route) { model.pendingRoute = route }
            }
            // `initial` picks up a quick action the scene delegate stored before this view existed.
            .onChange(of: model.pendingRoute, initial: true) { _, route in
                guard let route else { return }
                model.pendingRoute = nil
                open(route)
            }
        }
    }

    private func open(_ route: QuickRoute) {
        switch route {
        case .search:
            tab = "history"
            focusSearch = true
        case .pinboards:
            tab = "pinboards"
        case .history:
            tab = "history"
        case .keyboardSetup:
            tab = "settings"
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .saveClipboard:
            tab = "history"
            model.saveClipboard()
        case .copy(let id):
            tab = "history"
            model.copy(id: id)
        }
    }
}

#if DEBUG
/// `-CopydKeyboardPreview [-CopydKeyboardPreviewState noFullAccess|noStore|error|empty] [-CopydKeyboardPreviewMode pinned|work]`
/// shows the keyboard view at the bottom, fed with the real `KeyboardFeed`. Clip taps and keys are no-ops.
/// `-CopydKeyboardPreviewClipboard <text>` puts the keyboard's "Clipboard" card first in Recent.
private struct KeyboardPreviewHarness: View {
    let container: ModelContainer
    @State private var model = KeyboardModel()

    var body: some View {
        if UserDefaults.standard.bool(forKey: "CopydKeyboardPreview") {
            // `line` stands in for the system keyboard background, which the transparent keyboard relies on.
            KeyboardView(model: model).frame(height: 280)
                .background(DesignTokens.Brand.line)
                .task { load() }
        }
    }

    private func load() {
        let d = UserDefaults.standard
        let context = ModelContext(container)
        model.boards = (try? KeyboardFeed.boards(in: context)) ?? []
        switch d.string(forKey: "CopydKeyboardPreviewMode") {
        case "pinned": model.mode = .pinned
        case "work": model.mode = model.boards.first.map { .pinboard($0.id) } ?? .recent
        default: model.mode = .recent
        }
        model.showsGlobe = true
        model.lastSync = Date().addingTimeInterval(-300)
        model.onModeChange = { load() }
        switch d.string(forKey: "CopydKeyboardPreviewState") {
        case "noFullAccess": model.state = .noFullAccess
        case "noStore": model.state = .noStore
        case "error": model.state = .error
        default:
            let items = (try? KeyboardFeed.items(in: context, mode: model.mode)) ?? []
            let card = d.string(forKey: "CopydKeyboardPreviewClipboard").flatMap(ClipCapture.text)
                .map { KeyboardFeed.clipboardCard($0, now: Date()) }
            model.state = .loaded(model.mode == .recent ? (card.map { [$0] } ?? []) + items : items)
        }
    }
}

/// `-CopydWidgetPreview` shows the widget families at iPhone widget sizes, fed by the widget's own loader.
/// Medium rows are real links, so tapping one runs the `copy` route; the circular button runs the save intent.
private struct WidgetPreviewHarness: View {
    let container: ModelContainer
    @State private var state: RecentClipsState?

    var body: some View {
        if UserDefaults.standard.bool(forKey: "CopydWidgetPreview") {
            VStack(spacing: 16) {
                if let state {
                    RecentClipsMedium(state: state, now: .now).widgetFrame(width: 338, height: 158)
                    // One small per clip, so every card type shows; then the Lock Screen rectangular, which has
                    // no background or margins of its own.
                    let smalls = state.clips.isEmpty ? [state] : state.clips.map { RecentClipsState.clips([$0]) }
                    LazyVGrid(columns: [GridItem(.fixed(160), spacing: 18), GridItem(.fixed(160))], spacing: 16) {
                        ForEach(smalls.indices, id: \.self) { i in
                            RecentClipsSmall(state: smalls[i], now: .now).widgetFrame(width: 158, height: 158)
                        }
                        RecentClipsAccessory(state: state, now: .now).frame(width: 160, height: 72)
                    }
                    // The Lock Screen circular and inline families.
                    HStack(spacing: 18) {
                        // `AccessoryWidgetBackground` draws nothing outside WidgetKit; the material stands in for it.
                        LockScreenSaveView().frame(width: 76, height: 76).background(.ultraThinMaterial, in: Circle())
                        RecentClipsInline(state: state).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            .frame(width: 240, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.Brand.line)  // stands in for the wallpaper
            .task { state = .load(ModelContext(container)) }
        }
    }
}

/// `-CopydLiveActivityPreview YES` shows the Live Activity views for the newest clip of each kind: the Lock Screen
/// view, then the expanded and compact Dynamic Island assembled from the same pieces the island regions use.
private struct LiveActivityPreviewHarness: View {
    let container: ModelContainer
    @State private var states: [LatestClipActivity.ContentState] = []

    var body: some View {
        if UserDefaults.standard.bool(forKey: "CopydLiveActivityPreview") {
            VStack(spacing: 12) {
                ForEach(states, id: \.clipID) { state in
                    LatestClipLockScreen(state: state).frame(width: 360)
                        .background(DesignTokens.Brand.shelf, in: .rect(cornerRadius: 24))
                }
                if let state = states.first {
                    VStack(spacing: 8) {
                        HStack(alignment: .top) {
                            CopydMark(size: 30).padding(.leading, 6)
                            Spacer()
                            LatestClipAge(state: state).padding(.trailing, 6)
                        }
                        LatestClipIslandDetail(state: state)
                    }
                    .padding(EdgeInsets(top: 14, leading: 16, bottom: 18, trailing: 16))
                    .frame(width: 370)
                    .background(.black, in: .rect(cornerRadius: 44))
                    .environment(\.colorScheme, .dark)
                    HStack(spacing: 16) {
                        ForEach(states.prefix(3), id: \.clipID) { state in
                            HStack {
                                CopydMark(size: 20)
                                Spacer()
                                LatestClipCompact(state: state)
                            }
                            .padding(.horizontal, 12)
                            .frame(width: 112, height: 36)
                            .background(.black, in: Capsule())
                        }
                    }
                    .environment(\.colorScheme, .dark)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DesignTokens.Brand.line)  // stands in for the wallpaper
            .task { load() }
        }
    }

    private func load() {
        let clips = (try? ModelContext(container).fetch(FetchDescriptor<ClipboardItem>(
            sortBy: [SortDescriptor(\.copiedAt, order: .reverse)]))) ?? []
        var seen: Set<LatestClipActivity.ContentState.Kind> = []
        states = clips.filter { $0.contentType != .files && $0.contentType != .fileURL && !$0.isSensitive }
            .map(LatestClipActivity.ContentState.init)
            .filter { seen.insert($0.kind).inserted }
    }
}

/// `-CopydSharePreview YES` shows the share sheet twice, as sheets: sample text, then a sample image.
/// Save flips that sheet to its "Saved" state; nothing is written.
private struct SharePreviewHarness: View {
    @State private var text = ShareModel(phase: .ready, content: .text(
        "Meeting notes: ship the share extension, then check the widget on device. Bring the iPad for the split view test, and the old iPhone for iOS 17."))
    @State private var image = ShareModel(phase: .ready, content: .image(Self.sampleImage()))

    var body: some View {
        if UserDefaults.standard.bool(forKey: "CopydSharePreview") {
            VStack(spacing: 12) {
                sheet(text)
                sheet(image)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 60)
            .background(Color.black.opacity(0.4))
        }
    }

    private func sheet(_ model: ShareModel) -> some View {
        ShareView(model: model, onSave: { model.phase = .saved })
            .clipShape(RoundedRectangle(cornerRadius: 28))
    }

    private static func sampleImage() -> UIImage? {
        let png = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 800)).pngData { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
            UIColor.systemYellow.setFill(); ctx.fill(CGRect(x: 300, y: 200, width: 600, height: 400))
        }
        return Thumbnail.png(from: png).flatMap(UIImage.init(data:))
    }
}

private extension View {
    /// The system's 16 pt content margins and the widget's rounded `shelf` background.
    func widgetFrame(width: CGFloat, height: CGFloat) -> some View {
        padding(16).frame(width: width, height: height)
            .background(DesignTokens.Brand.shelf, in: .rect(cornerRadius: 22))
    }
}
#endif
