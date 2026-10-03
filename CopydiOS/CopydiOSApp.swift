import SwiftUI
import SwiftData
import UIKit

/// CKSyncEngine registers its own subscription and handles the push; this only completes the callback.
final class AppDelegate: NSObject, UIApplicationDelegate {
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

/// Hands Home Screen quick actions to `AppModel.pendingRoute`. SwiftUI's `WindowGroup` still owns the window,
/// so this never creates one.
@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    /// Cold launch: the item arrives with the connection options, before any view exists.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem { route(item) }
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
            #endif
            .environment(model)
            .modelContainer(model.container)
            // fetchIfStale is a no-op when sync is off (no engine) and throttles itself to 30 s.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.sync.fetchIfStale() }
            }
            .onOpenURL { url in
                if let route = QuickRoute(url: url) { model.pendingRoute = route }
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
        case .keyboardSetup:
            tab = "settings"
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .saveClipboard:
            tab = "history"
            model.saveClipboard()
        }
    }
}

#if DEBUG
/// `-CopydKeyboardPreview [-CopydKeyboardPreviewState noFullAccess|noStore|error|empty] [-CopydKeyboardPreviewMode pinned]`
/// shows the keyboard view at the bottom, fed with the real `KeyboardFeed`. Clip taps and keys are no-ops.
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
        model.mode = d.string(forKey: "CopydKeyboardPreviewMode") == "pinned" ? .pinned : .recent
        model.showsGlobe = true
        model.lastSync = Date().addingTimeInterval(-300)
        model.onModeChange = { load() }
        switch d.string(forKey: "CopydKeyboardPreviewState") {
        case "noFullAccess": model.state = .noFullAccess
        case "noStore": model.state = .noStore
        case "error": model.state = .error
        default:
            model.state = .loaded((try? KeyboardFeed.items(in: ModelContext(container), mode: model.mode)) ?? [])
        }
    }
}
#endif
