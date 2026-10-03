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
}

@main
struct CopydiOSApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    #if DEBUG
    @State private var tab = UserDefaults.standard.string(forKey: "CopydInitialTab") ?? "history"
    #else
    @State private var tab = "history"
    #endif

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                HistoryView().tabItem { Label("History", systemImage: "clock") }.tag("history")
                PinboardsView().tabItem { Label("Pinboards", systemImage: "pin") }.tag("pinboards")
                SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
            }
            .tint(DesignTokens.Brand.ink)
            .overlay(alignment: .bottom) { CopiedToast(visible: model.toastVisible) }
            #if DEBUG
            .overlay(alignment: .bottom) { KeyboardPreviewHarness(container: model.container) }
            #endif
            .environment(model)
            .modelContainer(model.container)
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
            KeyboardView(model: model).frame(height: 280)
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
