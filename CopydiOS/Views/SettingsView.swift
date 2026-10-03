import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
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
