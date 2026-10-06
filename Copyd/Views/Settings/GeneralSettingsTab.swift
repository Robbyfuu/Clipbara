import SwiftUI
import SwiftData
import ServiceManagement
import UniformTypeIdentifiers

struct GeneralSettingsTab: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @AppStorage("historyLimit") private var historyLimit: Int = 500
    @AppStorage(PasteService.alwaysPlainTextDefaultsKey) private var alwaysPastePlainText: Bool = false
    @AppStorage(AutoPaster.enabledDefaultsKey) private var autoPasteOnPick: Bool = true
    @AppStorage(SuggestedRow.enabledDefaultsKey) private var showSuggestions: Bool = true
    @AppStorage(SuggestionModel.enabledDefaultsKey) private var useAppleIntelligence: Bool = true
    @AppStorage(SecretDetector.protectDefaultsKey) private var protectSecrets: Bool = true
    @AppStorage(SecretSweeper.deleteAfterDefaultsKey) private var deleteSecretsAfter: Int = SecretSweeper.defaultMinutes
    @AppStorage(LinkPreviewPlan.enabledDefaultsKey) private var linkPreviews: Bool = true
    /// Re-read whenever Copyd comes back to the front, e.g. from System Settings.
    @State private var hasPasteAccess = CGPreflightPostEventAccess()
    @AppStorage(CloudSyncEngine.enabledDefaultsKey) private var iCloudSyncEnabled: Bool = false
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var transferMessage: String?
    @State private var showTransferAlert = false

    @ViewBuilder
    private var syncStatusText: some View {
        switch appState.cloudSync?.status ?? .off {
        case .off: Text("Off")
        case .syncing: Text("Syncing\u{2026}")
        case .upToDate(let date):
            Text("Up to date \u{00b7} \(date.formatted(.relative(presentation: .named)))")
        case .accountUnavailable: Text("iCloud account unavailable")
        case .quotaExceeded: Text("iCloud storage full")
        case .accountChanged: Text("iCloud account changed. Sync is off.")
        case .error(let message): Text("Sync error: \(message)")
        }
    }

    var body: some View {
        Form {
            Picker("History Limit", selection: $historyLimit) {
                Text("100").tag(100)
                Text("500").tag(500)
                Text("1,000").tag(1000)
                Text("5,000").tag(5000)
                Text("Unlimited").tag(0)
            }
            .pickerStyle(.menu)

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = !newValue
                    }
                }

            // Off: nothing is fetched, and link cards show the domain and path.
            Toggle("Link previews", isOn: $linkPreviews)
                .onChange(of: linkPreviews) { _, on in
                    if on { appState.linkPreviews?.fill() } else { appState.linkPreviews?.stop() }
                }

            Section("Pasting") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Paste directly into the app", isOn: $autoPasteOnPick)
                    if autoPasteOnPick && !hasPasteAccess {
                        HStack {
                            Text("Needs Accessibility access. Until then, picking a clip only copies it.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Accessibility Settings") {
                                appState.autoPaster.openAccessibilitySettings()
                            }
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    hasPasteAccess = appState.autoPaster.hasAccess
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text("Always Paste as Plain Text")
                            InfoHoverButton(text: "Removes fonts, colors, and links from rich text and HTML clips, pasting only the text.")
                        }
                        Text("Hold \u{21e7} while pasting to switch for a single paste.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $alwaysPastePlainText)
                        .labelsHidden()
                }

                Toggle("Show suggestions", isOn: $showSuggestions)
                if SuggestionModel.isAvailable {
                    Toggle("Use Apple Intelligence", isOn: $useAppleIntelligence)
                        .padding(.leading, 20)
                        .disabled(!showSuggestions)
                }
            }

            Section {
                Toggle("Protect secrets", isOn: $protectSecrets)
                Picker("Delete secrets after", selection: $deleteSecretsAfter) {
                    ForEach(SecretSweeper.choices, id: \.self) { minutes in
                        if minutes > 0 { Text("\(minutes) min").tag(minutes) } else { Text("Never").tag(minutes) }
                    }
                }
                .pickerStyle(.menu)
                // Off, nothing is swept: `SecretSweeper.deleteAfter` is nil.
                .disabled(!protectSecrets)
            } header: {
                Text("Secrets")
            } footer: {
                Text("Detected secrets stay on this device, show masked, and are deleted after this time unless pinned.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("iCloud Sync") {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Sync with iCloud", isOn: $iCloudSyncEnabled)
                    syncStatusText
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .onChange(of: iCloudSyncEnabled) { _, enabled in
                    if enabled {
                        appState.cloudSync?.start()
                    } else {
                        appState.cloudSync?.stop(clearState: true)
                    }
                }
            }

            Section("Backup") {
                LabeledContent("Export history, pinboards, and settings to a JSON file.") {
                    Button("Export\u{2026}") { exportHistory() }
                }
                LabeledContent("Import a backup file. Existing clips are kept; duplicates are skipped.") {
                    Button("Import\u{2026}") { importHistory() }
                }
            }

            Section {
                LabeledContent("Replay the first-run welcome tour.") {
                    Button("Show Welcome Tour\u{2026}") { showWelcomeTour() }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Backup", isPresented: $showTransferAlert, presenting: transferMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func showWelcomeTour() {
        guard let container = appState.modelContainer else { return }
        OnboardingWindowController.shared.show(appState: appState, modelContainer: container)
    }

    private func exportHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "clipbara-backup.json"
        panel.title = String(localized: "Export Copyd Backup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try TransferService.exportDocument(context: modelContext)
            try data.write(to: url)
            transferMessage = String(localized: "Backup exported successfully.")
        } catch {
            transferMessage = String(localized: "Export failed: \(error.localizedDescription)")
        }
        showTransferAlert = true
    }

    private func importHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = String(localized: "Import Clipbara Backup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let summary = try TransferService.importDocument(data, context: modelContext)
            transferMessage = summary.localizedMessage
        } catch {
            transferMessage = String(localized: "Import failed: \(error.localizedDescription)")
        }
        showTransferAlert = true
    }
}
