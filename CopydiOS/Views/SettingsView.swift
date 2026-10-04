import ActivityKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    /// Re-read each time the app comes to the front, e.g. back from Settings.
    @State private var keyboardStatus = PermissionStatus.unconfirmed
    @State private var fullAccessSeenAt: Date?
    @AppStorage(AppModel.liveActivityKey) private var liveActivityEnabled = false
    @AppStorage(AppModel.arrivalNotificationsKey) private var arrivalNotificationsEnabled = false
    /// Live Activities can be turned off for Copyd in Settings; re-read on every return to the app.
    @State private var activitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
    @State private var notificationsDenied = false
    #if DEBUG
    /// `-CopydShowQuickGuide YES` (with `-CopydInitialTab settings`) opens the Back Tap guide at launch.
    @State private var showQuickGuide = UserDefaults.standard.bool(forKey: "CopydShowQuickGuide")
    #else
    @State private var showQuickGuide = false
    #endif

    private var statusText: String {
        switch model.sync.status {
        case .off, .accountChanged: String(localized: "Off")
        case .syncing: String(localized: "Syncing\u{2026}")
        case .upToDate(let date):
            String(localized: "Up to date \u{00b7} \(date.formatted(.relative(presentation: .named)))")
        case .accountUnavailable: String(localized: "Sign in to iCloud to see your history")
        case .quotaExceeded: String(localized: "iCloud storage full")
        case .error(let message): String(localized: "Sync error: \(message)")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle(text: String(localized: "Settings")).padding(.bottom, 24)

                sectionLabel("Permissions")
                VStack(alignment: .leading, spacing: 0) {
                    let iCloud = PermissionStatus.resolve(granted: model.sync.status != .accountUnavailable,
                                                          featureOn: model.sync.status != .off)
                    permissionRow("iCloud", symbol: "icloud", status: iCloud,
                                  fix: iCloud == .missing ? "Sign in to iCloud" : nil)
                    Divider().overlay(DesignTokens.Brand.line)
                    permissionRow("Copyd keyboard added", symbol: "keyboard", status: keyboardStatus,
                                  fix: keyboardStatus == .granted ? nil : "Open Settings")
                    Divider().overlay(DesignTokens.Brand.line)
                    let fullAccess = PermissionStatus.resolve(fullAccessSeenAt: fullAccessSeenAt, now: .now)
                    permissionRow("Full Access", symbol: "lock.open", status: fullAccess,
                                  chip: fullAccess == .granted ? fullAccessSeenAt.map {
                                      Text("Allowed \u{00b7} confirmed \($0.formatted(.relative(presentation: .named)))")
                                  } : nil,
                                  hint: fullAccess == .unconfirmed
                                      ? "Not confirmed yet \u{2014} open the Copyd keyboard once" : nil,
                                  fix: fullAccess == .unconfirmed ? "Open Settings" : nil)
                    Divider().overlay(DesignTokens.Brand.line)
                    // No public API reads this setting, so the row never claims a state.
                    permissionRow("Paste from other apps", symbol: "doc.on.clipboard", status: .unconfirmed,
                                  hint: "Set to Allow to skip the paste prompt.", fix: "Open Settings")
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .brandCard()
                .padding(.bottom, 24)

                sectionLabel("Lock Screen & alerts")
                VStack(alignment: .leading, spacing: 0) {
                    if activitiesAllowed {
                        toggleRow("Show latest clip on Lock Screen", symbol: "lock.rectangle", isOn: $liveActivityEnabled)
                    } else {
                        permissionRow("Show latest clip on Lock Screen", symbol: "lock.rectangle", status: .missing,
                                      hint: "Turn on Live Activities for Copyd in Settings.", fix: "Open Settings")
                    }
                    Divider().overlay(DesignTokens.Brand.line)
                    if notificationsDenied {
                        permissionRow("Notify me when a clip arrives", symbol: "bell", status: .missing,
                                      hint: "Allow notifications for Copyd in Settings.", fix: "Open Settings")
                    } else {
                        toggleRow("Notify me when a clip arrives", symbol: "bell", isOn: $arrivalNotificationsEnabled)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .brandCard()
                .padding(.bottom, 24)

                sectionLabel("iCloud")
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Sync").brandFont(16, .semibold)
                    Spacer(minLength: 8)
                    Text(statusText).brandFont(15, relativeTo: .subheadline)
                        .foregroundStyle(DesignTokens.Brand.ink2)
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .brandCard()
                .padding(.bottom, 24)

                sectionLabel("Use the Copyd keyboard")
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("Open Copyd in Settings", systemImage: "gear")
                            .brandFont(17, .bold)
                            .foregroundStyle(DesignTokens.Brand.onButter)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(ButterButtonStyle())
                    .accessibilityLabel("Open Copyd in Settings")
                    Text("1. Tap Open Copyd in Settings")
                    Text("2. Tap Keyboards")
                    Text("3. Turn on Copyd and Allow Full Access")
                }
                .brandFont(16)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .brandCard()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Full Access lets the keyboard read your Copyd history. Copyd never sends what you type anywhere.")
                    Text("To skip the paste prompt: Settings \u{2192} Apps \u{2192} Copyd \u{2192} Paste from Other Apps \u{2192} Allow")
                }
                .brandFont(13, relativeTo: .footnote)
                .foregroundStyle(DesignTokens.Brand.ink2)
                .padding(.horizontal, 4)
                .padding(.top, 8)
                .padding(.bottom, 24)

                sectionLabel("Shortcuts & Back Tap")
                VStack(alignment: .leading, spacing: 12) {
                    Button { showQuickGuide = true } label: {
                        Label("Quick setup", systemImage: "hand.tap")
                            .brandFont(17, .bold)
                            .foregroundStyle(DesignTokens.Brand.onButter)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(ButterButtonStyle())
                    Button {
                        if let url = URL(string: "shortcuts://create-shortcut") { openURL(url) }
                    } label: {
                        Label("Open Shortcuts", systemImage: "square.2.layers.3d")
                            .brandFont(15, .semibold)
                            .foregroundStyle(DesignTokens.Brand.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(DesignTokens.Brand.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Text("1. Open Shortcuts \u{2192} + \u{2192} Add Action \u{2192} search Copyd \u{2192} Save Clipboard")
                    Text("2. Save the shortcut")
                    Text("3. Open Settings \u{2192} Accessibility \u{2192} Touch \u{2192} Back Tap \u{2192} Double Tap \u{2192} pick your shortcut")
                }
                .brandFont(16)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .brandCard()
            }
            .foregroundStyle(DesignTokens.Brand.ink)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(DesignTokens.Brand.shelf)
        .sheet(isPresented: $showQuickGuide) { QuickGuideView() }
        .onChange(of: liveActivityEnabled) { model.updateLiveActivity() }
        .onChange(of: arrivalNotificationsEnabled) { _, on in
            guard on else { return }
            Task {
                // Asks once; after a "Don't Allow" iOS answers false at once, and only Settings can change it.
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                notificationsDenied = !granted
                if !granted { arrivalNotificationsEnabled = false }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            activitiesAllowed = ActivityAuthorizationInfo().areActivitiesEnabled
            if notificationsDenied {
                Task {
                    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    if status != .denied { notificationsDenied = false }  // allowed in Settings: the toggle is back
                }
            }
            fullAccessSeenAt = SharedDefaults.store?.object(forKey: SharedDefaults.keyboardFullAccessSeenAtKey) as? Date
            keyboardStatus = .resolve(enabledKeyboards: UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String],
                                      fullAccessSeenAt: fullAccessSeenAt)
        }
    }

    /// A switch row laid out like `permissionRow`.
    private func toggleRow(_ name: LocalizedStringKey, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(DesignTokens.Brand.ink2)
                .frame(width: 22)
                .accessibilityHidden(true)
            Toggle(name, isOn: isOn).brandFont(16, .semibold)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    /// One permissions card row. `chip` defaults to the status's own label; `fix` opens Copyd in Settings.
    private func permissionRow(_ name: LocalizedStringKey, symbol: String, status: PermissionStatus, chip: Text? = nil,
                               hint: LocalizedStringKey? = nil, fix: LocalizedStringKey?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(DesignTokens.Brand.ink2)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).brandFont(16, .semibold)
                    Spacer(minLength: 8)
                    PermissionChip(status: status, label: chip ?? chipLabel(status))
                }
                if let hint {
                    Text(hint)
                        .brandFont(13, relativeTo: .footnote)
                        .foregroundStyle(DesignTokens.Brand.ink2)
                }
                if let fix {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Text(fix)
                            .brandFont(15, .semibold)
                            .foregroundStyle(DesignTokens.Brand.ink)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(DesignTokens.Brand.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 14)
    }

    private func chipLabel(_ status: PermissionStatus) -> Text {
        switch status {
        case .granted: Text("Allowed")
        case .missing: Text("Not allowed")
        // Its own key: plain "Off" is the sync status, which reads differently in Spanish.
        case .notNeeded:
            Text(String(localized: "Permission.notNeeded", defaultValue: "Off",
                        comment: "Chip on a permission whose feature is turned off"))
        case .unconfirmed: Text("Check in Settings")
        }
    }

    private func sectionLabel(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .brandFont(13, .semibold, relativeTo: .footnote)
            .foregroundStyle(DesignTokens.Brand.ink2)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}
