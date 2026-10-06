import SwiftUI
import SwiftData

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            PermissionsSettingsTab()
                .tabItem {
                    Label("Permissions", systemImage: "checkmark.shield")
                }

            AppearanceSettingsTab()
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            ShortcutSettingsTab()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            ExclusionSettingsTab()
                .tabItem {
                    Label("Exclusions", systemImage: "nosign")
                }

            IntegrationsSettingsTab()
                .tabItem {
                    Label("Integrations", systemImage: "puzzlepiece.extension")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        // Wide enough for seven tabs in the toolbar, in English and Spanish; tall enough for Integrations without scrolling.
        .frame(width: 560, height: 440)
    }
}
