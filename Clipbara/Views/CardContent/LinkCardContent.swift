import SwiftUI

struct LinkCardContent: View {
    let item: ClipboardItem
    var searchText: String = ""

    private var urlString: String {
        item.textContent ?? ""
    }

    private var parsed: URL? { URL(string: urlString) }

    private var domain: String {
        parsed?.host ?? urlString
    }

    private var path: String {
        guard let url = parsed, url.host != nil else { return "" }
        let tail = url.path + (url.query.map { "?\($0)" } ?? "")
        return tail == "/" ? "" : tail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)

            Text(TextHighlighter.highlight(domain, query: searchText))
                .font(.system(size: 17, weight: .bold))
                .lineLimit(2)
                .foregroundStyle(DesignTokens.Brand.ink)

            if !path.isEmpty {
                Text(TextHighlighter.highlight(path, query: searchText))
                    .font(.system(size: 11).monospaced())
                    .lineLimit(3)
                    .foregroundStyle(DesignTokens.Brand.ink2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(DesignTokens.Brand.chip)
    }
}
