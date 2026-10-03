import SwiftUI
import SwiftData

/// One clip card. Tap copies; swipe pins or deletes. `onDelete` lets Pinboards remove the entry instead of the clip.
struct ClipRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    let item: ClipboardItem
    var onDelete: (() -> Void)?

    var body: some View {
        Button { model.copy(item) } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .brandCard()
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .brandRow(top: 5, bottom: 5)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { if let onDelete { onDelete() } else { deleteClip() } } label: { Label("Delete", systemImage: "trash") }
            Button {
                item.isPinned.toggle()
                try? modelContext.save()
            } label: { Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") }
            .tint(DesignTokens.Brand.butter)
        }
    }

    @ViewBuilder private var content: some View {
        if item.contentType == .image {
            HStack(spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(title ?? "Image").brandFont(16, .semibold).lineLimit(1)
                        .foregroundStyle(DesignTokens.Brand.ink)
                    meta
                }
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 16))
        } else if item.contentType == .color {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: item.textContent ?? "") ?? DesignTokens.Brand.chip)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
                    .frame(width: 60, height: 60)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.textContent ?? "").brandFont(14, design: .monospaced)
                        .foregroundStyle(DesignTokens.Brand.ink)
                    meta
                }
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 16))
        } else if item.contentType == .url, let parts = LinkParts.split(item.textContent ?? "") {
            VStack(alignment: .leading, spacing: 6) {
                Text(parts.host).brandFont(18, .bold).tracking(-0.18).lineLimit(1)
                    .foregroundStyle(DesignTokens.Brand.ink)
                if !parts.rest.isEmpty {
                    Text(parts.rest).brandFont(12, design: .monospaced, relativeTo: .caption)
                        .foregroundStyle(DesignTokens.Brand.ink2)
                        .lineLimit(2).truncationMode(.middle)
                }
                meta
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(title ?? item.textContent ?? "").brandFont(16).lineSpacing(3).lineLimit(4)
                    .foregroundStyle(DesignTokens.Brand.ink)
                meta
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        }
    }

    private var title: String? { item.userTitle.flatMap { $0.isEmpty ? nil : $0 } }

    /// "Source · age" on the left; "Pinned" on the right when pinned.
    private var meta: some View {
        HStack(spacing: 8) {
            Text("\(item.sourceAppName ?? "Copyd") \u{00b7} \(ClipAge.text(from: item.copiedAt, now: Date()))")
                .foregroundStyle(DesignTokens.Brand.ink2)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.isPinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill").accessibilityHidden(true)
                    Text("Pinned")
                }
                .fontWeight(.semibold)
                .foregroundStyle(DesignTokens.Brand.butterInk)
            }
        }
        .brandFont(13, relativeTo: .footnote)
    }

    @ViewBuilder private var thumbnail: some View {
        if let data = item.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "photo").font(.system(size: 22))
                .foregroundStyle(DesignTokens.Brand.ink2)
                .frame(width: 60, height: 60)
                .background(DesignTokens.Brand.chip, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
        }
    }

    private func deleteClip() {
        let id = item.id
        let entries = (try? modelContext.fetch(FetchDescriptor<PinboardEntry>(predicate: #Predicate { $0.clipboardItem?.id == id }))) ?? []
        entries.forEach(modelContext.delete)
        modelContext.delete(item)
        try? modelContext.save()
    }
}
