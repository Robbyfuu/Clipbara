import SwiftUI
import AppKit

struct ImageCardContent: View {
    let item: ClipboardItem
    @State private var cachedImage: NSImage?

    var body: some View {
        DesignTokens.Brand.chip
            .overlay {
                if let image = cachedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(DesignTokens.Brand.ink2)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: item.id) {
                cachedImage = ThumbnailImageCache.image(for: item)
            }
    }
}
