import SwiftUI

/// A large swatch filling the card, with the HEX and RGB values below it.
struct ColorCardContent: View {
    let item: ClipboardItem

    var body: some View {
        let hex = item.textContent ?? ""
        VStack(alignment: .leading, spacing: 0) {
            (Color(hex: hex) ?? DesignTokens.Brand.chip)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: hex)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignTokens.Brand.ink)
                if let rgb = ColorFormat.rgbString(hex: hex) {
                    Text(verbatim: rgb)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DesignTokens.Brand.ink2)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Brand.chip)
        }
    }
}
