import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

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
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("Open Copyd in Settings", systemImage: "gear")
                            .brandFont(17, .bold)
                            .foregroundStyle(DesignTokens.Brand.onButter)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .accessibilityLabel("Open Copyd in Settings")
                    Text("1. Tap Open Copyd in Settings")
                    Text("2. Tap Keyboards")
                    Text("3. Turn on Copyd and Allow Full Access")
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

/// Butter primary button; `butterInk` at 20 % darkens it while pressed.
private struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14)
        configuration.label
            .background(DesignTokens.Brand.butter, in: shape)
            .overlay { if configuration.isPressed { shape.fill(DesignTokens.Brand.butterInk.opacity(0.2)) } }
            .contentShape(shape)
    }
}
