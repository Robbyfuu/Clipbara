import SwiftUI
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
            .environment(model)
            .modelContainer(model.container)
        }
    }
}
