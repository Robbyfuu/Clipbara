import SwiftUI

struct CopiedToast: View {
    let visible: Bool

    var body: some View {
        Text("Copied")
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
