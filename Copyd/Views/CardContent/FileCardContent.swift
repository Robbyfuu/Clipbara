import SwiftUI
import AppKit

struct FileCardContent: View {
    let item: ClipboardItem
    var searchText: String = ""
    @State private var cachedFileIcon: NSImage?

    private var fileName: String {
        item.textContent ?? "File"
    }

    private func loadFileIcon() -> NSImage {
        if let urlString = String(data: item.rawData, encoding: .utf8),
           let url = URL(string: urlString) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: cachedFileIcon ?? NSWorkspace.shared.icon(for: .data))
                .resizable()
                .frame(width: 36, height: 36)

            Text(TextHighlighter.highlight(fileName, query: searchText))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(DesignTokens.Brand.ink)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Brand.chip)
        .task(id: item.id) {
            cachedFileIcon = loadFileIcon()
        }
    }
}
