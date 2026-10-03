import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private var statusText: String {
        switch model.sync.status {
        case .off: "Off"
        case .syncing: "Syncing\u{2026}"
        case .upToDate(let date): "Up to date \u{00b7} \(date.formatted(.relative(presentation: .named)))"
        case .accountUnavailable: "Sign in to iCloud to see your history"
        case .quotaExceeded: "iCloud storage full"
        case .accountChanged: "iCloud account changed. Sync is off."
        case .error(let message): "Sync error: \(message)"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("iCloud") {
                    LabeledContent("Sync") { Text(statusText).foregroundStyle(DesignTokens.Brand.ink2) }
                }
                .listRowBackground(DesignTokens.Brand.card)
                Section {
                    Text("1. Open Settings \u{2192} General \u{2192} Keyboard \u{2192} Keyboards")
                    Text("2. Tap Add New Keyboard\u{2026} \u{2192} Copyd")
                    Text("3. Tap Copyd \u{2192} turn on Allow Full Access")
                } header: {
                    Text("Use the Copyd keyboard")
                } footer: {
                    Text("Full Access lets the keyboard read your Copyd history. Copyd never sends what you type anywhere.")
                }
                .listRowBackground(DesignTokens.Brand.card)
            }
            .foregroundStyle(DesignTokens.Brand.ink)
            .scrollContentBackground(.hidden)
            .background(DesignTokens.Brand.shelf)
            .navigationTitle("Settings")
        }
    }
}
