import SwiftUI
import SwiftData

/// One clip row. Tap copies; swipe pins or deletes. `onDelete` lets Pinboards remove the entry instead of the clip.
struct ClipRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    let item: ClipboardItem
    var onDelete: (() -> Void)?

    var body: some View {
        Button { model.copy(item) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    if item.contentType == .image {
                        thumbnail
                    } else {
                        Text(item.userTitle ?? item.textContent ?? "")
                            .lineLimit(3)
                            .foregroundStyle(DesignTokens.Brand.ink)
                    }
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(DesignTokens.Brand.ink2)
                }
                Spacer(minLength: 0)
                if item.isPinned {
                    Image(systemName: "pin.fill").font(.caption).foregroundStyle(DesignTokens.Brand.ink2)
                        .accessibilityLabel("Pinned")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(DesignTokens.Brand.card)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { onDelete?() ?? deleteClip() } label: { Label("Delete", systemImage: "trash") }
            Button {
                item.isPinned.toggle()
                try? modelContext.save()
            } label: { Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") }
            .tint(DesignTokens.Brand.butter)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let data = item.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Image")
        } else {
            Label("Image", systemImage: "photo").foregroundStyle(DesignTokens.Brand.ink)
        }
    }

    private var secondary: String {
        let when = item.copiedAt.formatted(.relative(presentation: .named))
        return [item.sourceAppName, when].compactMap { $0 }.joined(separator: " \u{00b7} ")
    }

    private func deleteClip() {
        let id = item.id
        let entries = (try? modelContext.fetch(FetchDescriptor<PinboardEntry>(predicate: #Predicate { $0.clipboardItem?.id == id }))) ?? []
        entries.forEach(modelContext.delete)
        modelContext.delete(item)
        try? modelContext.save()
    }
}
