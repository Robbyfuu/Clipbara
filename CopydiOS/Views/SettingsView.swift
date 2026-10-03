import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private var statusText: String {
        switch model.sync.status {
        case .off, .accountChanged: "Off"
        case .syncing: "Syncing\u{2026}"
        case .upToDate(let date): "Up to date \u{00b7} \(date.formatted(.relative(presentation: .named)))"
        case .accountUnavailable: "Sign in to iCloud to see your history"
        case .quotaExceeded: "iCloud storage full"
        case .error(let message): "Sync error: \(message)"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle(text: "Settings").padding(.bottom, 24)

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
                    Text("1. Open Settings \u{2192} General \u{2192} Keyboard \u{2192} Keyboards")
                    Text("2. Tap Add New Keyboard\u{2026} \u{2192} Copyd")
                    Text("3. Tap Copyd \u{2192} turn on Allow Full Access")
                }
                .brandFont(16)
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
                .brandCard()
                Text("Full Access lets the keyboard read your Copyd history. Copyd never sends what you type anywhere.")
                    .brandFont(13, relativeTo: .footnote)
                    .foregroundStyle(DesignTokens.Brand.ink2)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
            .foregroundStyle(DesignTokens.Brand.ink)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(DesignTokens.Brand.shelf)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .brandFont(13, .semibold, relativeTo: .footnote)
            .foregroundStyle(DesignTokens.Brand.ink2)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }
}
