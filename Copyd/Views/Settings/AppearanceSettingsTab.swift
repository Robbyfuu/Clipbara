import SwiftUI

enum AppTheme: String, CaseIterable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    /// Localized label. `rawValue` is what is stored in UserDefaults.
    var displayName: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

struct AppearanceSettingsTab: View {
    @AppStorage("appTheme") private var appTheme: String = AppTheme.system.rawValue

    var body: some View {
        Form {
            Picker("Theme", selection: $appTheme) {
                ForEach(AppTheme.allCases, id: \.rawValue) { theme in
                    Text(theme.displayName).tag(theme.rawValue)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: appTheme) { _, newValue in
                applyTheme(newValue)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            applyTheme(appTheme)
        }
    }

    private func applyTheme(_ theme: String) {
        switch AppTheme(rawValue: theme) {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
}
