import SwiftUI

struct TextCardContent: View {
    let item: ClipboardItem
    var searchText: String = ""
    @State private var isCode: Bool = false

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
        Group {
            if searchText.isEmpty {
                Text(previewText)
            } else {
                Text(TextHighlighter.highlight(previewText, query: searchText))
            }
        }
        .font(.system(size: 13, design: isCode ? .monospaced : .default))
        .lineSpacing(3)
        .multilineTextAlignment(.leading)
        .foregroundStyle(DesignTokens.Brand.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .mask(LinearGradient(
            stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
            startPoint: .top, endPoint: .bottom))
        .padding(10)
        .background(DesignTokens.Brand.chip)
        .task(id: item.id) {
            guard !item.isSensitive, let text = item.textContent else { return }
            let sample = text.prefix(900)
            let codeIndicators = ["func ", "var ", "let ", "class ", "import ", "def ", "return ", "{", "}", "=>", "->", "();", "//", "/*"]
            isCode = codeIndicators.contains { sample.contains($0) }
        }
    }
}
