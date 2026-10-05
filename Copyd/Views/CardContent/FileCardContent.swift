import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileCardContent: View {
    let item: ClipboardItem
    var searchText: String = ""
    @State private var cachedFileIcon: NSImage?

    private var fileName: String {
        item.textContent ?? "File"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: cachedFileIcon ?? NSWorkspace.shared.icon(for: .data))
                .resizable()
                .scaledToFit()
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
            cachedFileIcon = item.fileIcon
        }
    }
}

extension ClipboardItem {
    /// A `.fileURL` clip's Finder icon. A `.files` clip shows its image file's thumbnail, else the icon of its
    /// first file's type, taken from the name so the bundle is never read.
    var fileIcon: NSImage {
        if contentType == .files {
            if let data = thumbnailData, let image = NSImage(data: data) { return image }
            let first = textContent?.components(separatedBy: ", ").first ?? ""
            return NSWorkspace.shared.icon(for: UTType(filenameExtension: (first as NSString).pathExtension) ?? .data)
        }
        if let urlString = String(data: rawData, encoding: .utf8), let url = URL(string: urlString) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    /// A `.files` clip's total size, from its stored manifest so the bundle is never read. "Files" without one.
    var filesSizeText: String {
        guard let files = fileManifest else { return String(localized: "Files") }
        return ByteCountFormatter.string(fromByteCount: Int64(files.reduce(0) { $0 + $1.size }), countStyle: .file)
    }
}
