import SwiftUI

struct TextCardContent: View {
    let item: ClipboardItem
    var searchText: String = ""

    private var previewText: String {
        if let mask = item.secretMask { return mask }
        // Display only: leading blank lines (common in copied HTML) would push the text down the card.
        guard let text = item.textContent?.trimmingCharacters(in: .whitespacesAndNewlines) else { return "..." }
        let maxCharacters = 900
        if text.count <= maxCharacters {
            return text
        }
        return String(text.prefix(maxCharacters)) + "..."
    }

    var body: some View {
        let preview = previewText
        // A secret shows its mask, never code colors. The search highlight goes on top of the colors.
        let code = item.isSensitive ? nil : CodeStyle.attributed(preview, key: item.contentHash)
        Text(TextHighlighter.highlight(preview, query: searchText, over: code))
            .font(.system(size: 13, design: code == nil ? .default : .monospaced))
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .foregroundStyle(DesignTokens.Brand.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .mask(LinearGradient(
                stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom))
            .padding(10)
            .background(DesignTokens.Brand.chip)
    }
}
