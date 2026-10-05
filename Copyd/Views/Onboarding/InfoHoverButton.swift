import SwiftUI

/// A small ⓘ icon that shows a balloon popover with a short explanation on hover.
struct InfoHoverButton: View {
    let text: LocalizedStringKey
    var width: CGFloat = 250

    @State private var isShowing = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .onHover { hovering in
                isShowing = hovering
            }
            .popover(isPresented: $isShowing, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .padding(12)
                    .frame(width: width, alignment: .leading)
            }
            .accessibilityLabel("More info")
    }
}
