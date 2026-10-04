import OSLog
import SwiftUI

/// Which permissions Copyd has and which are missing, with a button to fix each missing one.
struct PermissionsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @AppStorage(AutoPaster.enabledDefaultsKey) private var autoPasteOnPick: Bool = true
    @AppStorage(CloudSyncEngine.enabledDefaultsKey) private var iCloudSyncEnabled: Bool = false
    @AppStorage(PasteStackController.everStartedDefaultsKey) private var pasteStackEverStarted: Bool = false
    /// Re-read when a window becomes key or Copyd comes back to the front, e.g. from System Settings.
    @State private var hasPasteAccess = CGPreflightPostEventAccess()
    @State private var hasListenAccess = CGPreflightListenEventAccess()

    var body: some View {
        Form {
            Section {
                row("Accessibility", symbol: "accessibility",
                    why: "Pastes a picked clip straight into your app.",
                    status: .resolve(granted: hasPasteAccess, featureOn: autoPasteOnPick)) {
                    appState.autoPaster.openAccessibilitySettings()
                }
                // Paste Stack has no on/off setting: the permission is needed once it has been started. Before that,
                // a fresh install (and App Review) would see "Not allowed" for a feature never used.
                row("Input Monitoring", symbol: "keyboard",
                    why: "Lets Paste Stack see \u{2318}V.",
                    status: .resolve(granted: hasListenAccess, featureOn: pasteStackEverStarted)) {
                    PasteStackController.openInputMonitoringSettings()
                }
                // The engine checks the account when sync starts and follows sign-in and sign-out after that.
                row("iCloud", symbol: "icloud",
                    why: "Syncs your history with your other devices.",
                    status: .resolve(granted: appState.cloudSync.map { $0.status != .accountUnavailable } ?? false,
                                     featureOn: iCloudSyncEnabled)) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section {
                LabeledContent("macOS may need Copyd to restart after you allow a permission.") {
                    Button("Restart Copyd") { restart() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func row(_ name: LocalizedStringKey, symbol: String, why: LocalizedStringKey, status: PermissionStatus,
                     fix: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(why)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if status == .missing {
                    Button("Open Settings", action: fix)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 8)
            PermissionChip(status: status, label: label(for: status))
        }
    }

    private func label(for status: PermissionStatus) -> Text {
        switch status {
        case .granted: return Text("Allowed")
        case .missing: return Text("Not allowed")
        case .unconfirmed:
            assertionFailure("Every Mac permission can be read: .unconfirmed is iOS only")
            fallthrough
        // Its own key: plain "Off" is the sync status, which reads differently in Spanish.
        case .notNeeded:
            return Text(String(localized: "Permission.notNeeded", defaultValue: "Off",
                               comment: "Chip on a permission whose feature is turned off"))
        }
    }

    private func refresh() {
        hasPasteAccess = appState.autoPaster.hasAccess
        hasListenAccess = CGPreflightListenEventAccess()
    }

    /// A new instance starts and, in `LaunchGuard`, waits for this one to quit. macOS grants some permissions only at launch.
    private func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-\(LaunchGuard.relaunchAfterPIDKey)", String(ProcessInfo.processInfo.processIdentifier)]
        // The new instance blocks in LaunchGuard until this pid is gone, and the completion may only
        // fire once it has finished launching: quit on success or after a short beat, never after an error.
        let launch = RelaunchState()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message { relaunchLog.error("Restart failed, Copyd stays open: \(message, privacy: .public)") }
                launch.launched = message == nil
                launch.quitIfReady()
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            launch.beatPassed = true
            launch.quitIfReady()
        }
    }
}

private let relaunchLog = Logger(subsystem: "com.robbyfuu.copyd", category: "Permissions")

/// What "Restart Copyd" knows so far: the running instance quits only per `LaunchGuard.restartQuits`.
@MainActor private final class RelaunchState {
    /// nil until `openApplication` reports.
    var launched: Bool?
    var beatPassed = false
    private var quitting = false

    func quitIfReady() {
        guard !quitting, LaunchGuard.restartQuits(launched: launched, beatPassed: beatPassed) else { return }
        quitting = true
        NSApp.terminate(nil)
    }
}
