import SwiftUI

/// The butter capsule that confirms a copy or a save ("Copied", "Saved", ...).
struct CopiedToast: View {
    let text: String
    let visible: Bool

    var body: some View {
        Text(text)
            .brandFont(15, .semibold, relativeTo: .subheadline)
            .foregroundStyle(DesignTokens.Brand.onButter)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(DesignTokens.Brand.butter, in: Capsule())
            .padding(.bottom, 100)
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: visible)
            .allowsHitTesting(false)
            .accessibilityHidden(!visible)
    }
}
