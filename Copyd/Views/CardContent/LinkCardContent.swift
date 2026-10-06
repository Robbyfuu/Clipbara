import SwiftUI

struct LinkCardContent: View {
    let item: ClipboardItem
    var searchText: String = ""
    @AppStorage(LinkPreviewPlan.enabledDefaultsKey) private var previewsOn = true
    /// The fetched image, decoded once per change rather than on every body pass.
    @State private var image: NSImage?

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
        Group {
            if previewsOn, item.linkPreviewTitle != nil || image != nil {
                preview
            } else {
                plain
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .background(DesignTokens.Brand.chip)
        // Data compares by bytes: the image arrives, or an edit clears it, and the card follows.
        .task(id: previewsOn ? item.linkImageData : nil) {
            image = previewsOn ? item.linkImageData.flatMap(NSImage.init(data:)) : nil
        }
    }

    /// The page's image on top (fill, clipped), then its title and the domain.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image {
                Color.clear
                    .overlay { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let title = item.linkPreviewTitle {
                    Text(TextHighlighter.highlight(title, query: searchText))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                        .foregroundStyle(DesignTokens.Brand.ink)
                }
                Text(TextHighlighter.highlight(domain, query: searchText))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(DesignTokens.Brand.ink2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// No preview, or previews off: the domain and the path.
    private var plain: some View {
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
    }
}
