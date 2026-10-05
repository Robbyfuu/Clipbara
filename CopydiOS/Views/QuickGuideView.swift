import SwiftUI

/// Back Tap setup in three steps. Back Tap only lists shortcuts already in the library and no public URL opens its
/// screen, so step 1 shares a signed shortcut (built by `scripts/make-backtap-shortcut.sh`) and step 2 is directions.
struct QuickGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 28

    /// Shortcuts names the imported shortcut after the file, so there is one file per language.
    private static let shortcutURL = Bundle.main.url(forResource: String(localized: "Save to Copyd"), withExtension: "shortcut")

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CopydWordmark(size: 28)
                    Spacer(minLength: 12)
                    Button("Done") { dismiss() }
                        .brandFont(17, .semibold)
                        .frame(minHeight: 44)
                }
                ScreenTitle(text: String(localized: "Back Tap in 3 steps"))
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                step(1, "Add the shortcut") {
                    if let url = Self.shortcutURL {
                        ShareLink(item: url) {
                            Label("Add shortcut", systemImage: "plus")
                                .brandFont(17, .bold)
                                .foregroundStyle(DesignTokens.Brand.onButter)
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                        .buttonStyle(ButterButtonStyle())
                    }
                    Text("Choose Shortcuts, then Add Shortcut.").secondaryNote()
                }
                step(2, "Turn on Back Tap") {
                    Text("Settings \u{2192} Accessibility \u{2192} Touch \u{2192} Back Tap \u{2192} Double Tap \u{2192} Save to Copyd")
                    Text("iOS doesn't let apps open this screen directly.").secondaryNote()
                }
                step(3, "Try it") {
                    Text("Copy something and tap the back of your iPhone twice.")
                }

                Text("Have an Action button? Settings \u{2192} Action Button \u{2192} Shortcut \u{2192} Copyd \u{2192} Save Clipboard. No shortcut needed.")
                    .brandFont(15, relativeTo: .subheadline)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.Brand.butterSoft, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.top, 12)
            }
            .foregroundStyle(DesignTokens.Brand.ink)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(DesignTokens.Brand.shelf)
    }

    private func step<Content: View>(_ number: Int, _ title: LocalizedStringResource,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(number, format: .number)
                .brandFont(15, .bold)
                .foregroundStyle(DesignTokens.Brand.onButter)
                .frame(width: badge, height: badge)
                .background(DesignTokens.Brand.butter, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).brandFont(17, .bold).accessibilityAddTraits(.isHeader)
                content()
            }
            .brandFont(16)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandCard()
    }
}

@MainActor private extension Text {
    func secondaryNote() -> some View {
        brandFont(13, relativeTo: .footnote).foregroundStyle(DesignTokens.Brand.ink2)
    }
}
