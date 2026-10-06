import SwiftUI

/// A large swatch filling the card, with the RGB value below it. The card's footer already shows the HEX.
struct ColorCardContent: View {
    let item: ClipboardItem

    var body: some View {
        let hex = item.textContent ?? ""
        VStack(alignment: .leading, spacing: 0) {
            (Color(hex: hex) ?? DesignTokens.Brand.chip)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let rgb = ColorFormat.rgbString(hex: hex) {
                Text(verbatim: rgb)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(DesignTokens.Brand.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.Brand.chip)
            }
        }
    }
}
