import SwiftUI
import SwiftData

/// One clip card. Tap copies (a file clip opens the share sheet); swipe pins or deletes; long-press offers "Copy as…",
/// "Copy text" for an image whose text was read, and "Edit". `onDelete` lets Pinboards remove the entry instead of the clip.
struct ClipRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    let item: ClipboardItem
    var onDelete: (() -> Void)?
    @State private var editing = false
    @AppStorage(LinkPreviewPlan.enabledDefaultsKey, store: SharedDefaults.store) private var linkPreviewsOn = true

    var body: some View {
        // The sweep, a sync or another row's delete may have removed the clip: reading it then would crash.
        if item.isGone {
            EmptyView()
        } else {
            row
        }
    }

    private var row: some View {
        Button { if item.contentType == .files { model.share(item) } else { model.copy(item) } } label: {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .brandCard()
                .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .contextMenu {
            CopyAsMenu(item: item)
            if let text = item.recognizedText {
                Button { model.copy(item, text: text) } label: { Label("Copy text", systemImage: "text.viewfinder") }
            }
            // Never for a secret: the editor would show it.
            if item.isEditable {
                Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
            }
        }
        .sheet(isPresented: $editing) { EditClipSheet(item: item) }
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
                    Text(title ?? String(localized: "Image")).brandFont(16, .semibold).lineLimit(1)
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
                    if let title { mainLine(title) }
                    Text(item.textContent ?? "").brandFont(14, design: .monospaced)
                        .foregroundStyle(DesignTokens.Brand.ink)
                    meta
                }
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 16))
        } else if item.contentType == .files {
            // The stored manifest, never rawData: reading the bundle here would load up to 48 MB per row.
            let files = item.fileManifest
            HStack(spacing: 14) {
                fileIcon(files)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title ?? filesTitle(files)).brandFont(16, .semibold).lineLimit(2)
                        .foregroundStyle(DesignTokens.Brand.ink)
                    if let detail = filesDetail(files) {
                        Text(verbatim: detail).brandFont(12, design: .monospaced, relativeTo: .caption)
                            .foregroundStyle(DesignTokens.Brand.ink2)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    meta
                }
            }
            .padding(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 16))
        } else if let mask = item.secretMask {
            // A secret shows its masked label, whatever its type. A tap still copies the secret itself.
            VStack(alignment: .leading, spacing: 8) {
                mainLine(title ?? mask)
                meta
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        } else if let parts = linkParts {
            // The fetched preview: the page's image as a thumbnail, its title, and the domain under it.
            let pageTitle = linkPreviewsOn ? item.linkPreviewTitle : nil
            let image = linkPreviewsOn ? linkImage : nil
            HStack(spacing: 14) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let heading = title ?? pageTitle {
                        mainLine(heading)
                        // A user title keeps the whole link under it; a page title, the domain.
                        Text(title == nil ? parts.host : parts.host + parts.rest)
                            .brandFont(12, design: .monospaced, relativeTo: .caption)
                            .foregroundStyle(DesignTokens.Brand.ink2)
                            .lineLimit(2).truncationMode(.middle)
                    } else {
                        Text(parts.host).brandFont(18, .bold).tracking(-0.18).lineLimit(1)
                            .foregroundStyle(DesignTokens.Brand.ink)
                        if !parts.rest.isEmpty {
                            Text(parts.rest).brandFont(12, design: .monospaced, relativeTo: .caption)
                                .foregroundStyle(DesignTokens.Brand.ink2)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                    meta
                }
            }
            .padding(image == nil ? EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
                                  : EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 16))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                mainLine(title ?? item.textContent ?? "")
                meta
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        }
    }

    private func mainLine(_ text: String) -> some View {
        Text(text).brandFont(16).lineSpacing(3).lineLimit(4)
            .foregroundStyle(DesignTokens.Brand.ink)
    }

    private var title: String? { item.userTitle.flatMap { $0.isEmpty ? nil : $0 } }

    /// One file's name, or "3 files". "Files" for a clip stored without a manifest.
    private func filesTitle(_ files: [FileManifestEntry]?) -> String {
        guard let files, files.count > 1 else { return files?.first?.name ?? String(localized: "Files") }
        return String(localized: "\(files.count) files", comment: "Title of a clip holding several copied files")
    }

    /// The total size, after the names when there are several files. None without a manifest.
    private func filesDetail(_ files: [FileManifestEntry]?) -> String? {
        guard let files else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(files.reduce(0) { $0 + $1.size }), countStyle: .file)
        return files.count > 1 ? "\(item.textContent ?? "") \u{00b7} \(size)" : size
    }

    /// An image file's thumbnail, else a document symbol: one page, or a stack for several files.
    @ViewBuilder private func fileIcon(_ files: [FileManifestEntry]?) -> some View {
        if let data = item.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
        } else {
            Image(systemName: (files?.count ?? 1) > 1 ? "doc.on.doc" : "doc").font(.system(size: 22))
                .foregroundStyle(DesignTokens.Brand.ink2)
                .frame(width: 60, height: 60)
                .background(DesignTokens.Brand.chip, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
        }
    }

    /// A link's fetched image, decoded by ImageIO at the 60 pt thumbnail's pixel size, never the full 640 px.
    private var linkImage: UIImage? {
        guard item.contentType == .url, !item.isSensitive, let data = item.linkImageData else { return nil }
        return Thumbnail.image(from: data, maxPixels: 180).map(UIImage.init(cgImage:))
    }

    /// Link clips, and text clips that are nothing but one http(s) URL, render as the link card.
    private var linkParts: (host: String, rest: String)? {
        switch item.contentType {
        case .url: LinkParts.split(item.textContent ?? "")
        case .plainText, .richText, .html: LinkParts.bareLink(item.textContent ?? "")
        default: nil
        }
    }

    /// "Source · age" on the left; a lock for a secret, and "Pinned" when pinned, on the right.
    private var meta: some View {
        HStack(spacing: 8) {
            Text("\(item.sourceAppName ?? "Copyd") \u{00b7} \(ClipAge.text(from: item.copiedAt, now: Date()))")
                .foregroundStyle(DesignTokens.Brand.ink2)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.recognizedText != nil {
                Text(verbatim: "Aa")
                    .fontWeight(.bold)
                    .foregroundStyle(DesignTokens.Brand.ink)
                    .padding(.horizontal, 5)
                    .background(DesignTokens.Brand.chip, in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Text found in this image")
            }
            if item.isSensitive {
                Image(systemName: "lock.fill")
                    .foregroundStyle(DesignTokens.Brand.butterInk)
                    .accessibilityLabel("Secret, kept on this device")
            }
            if item.isPinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill").accessibilityHidden(true)
                    Text(String(localized: "Pinned.badge", defaultValue: "Pinned", comment: "Badge on one pinned clip"))
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

/// "Copy as…", with only the transforms that change this clip. Its own view, so they are worked out again only when
/// the clip changes. None for a secret.
private struct CopyAsMenu: View {
    @Environment(AppModel.self) private var model
    let item: ClipboardItem

    var body: some View {
        let transforms = item.pasteAsTransforms
        if !transforms.isEmpty {
            Menu("Copy as…") {
                ForEach(transforms, id: \.self) { transform in
                    Button(transform.label()) {
                        // The sweep or a sync may have deleted the clip while the menu was open.
                        guard !item.isGone, let text = item.textContent.flatMap(transform.apply(to:)) else { return }
                        model.copy(item, text: text)
                    }
                }
            }
        }
    }
}

/// Edits a text clip. Saving stores plain text with a new hash; the sync tracker uploads it as an update.
private struct EditClipSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: ClipboardItem
    @State private var text: String
    @FocusState private var focused: Bool

    init(item: ClipboardItem) {
        self.item = item
        _text = State(initialValue: item.isGone ? "" : item.textContent ?? "")
    }

    var body: some View {
        if item.isGone {
            EmptyView()
        } else {
            editor
        }
    }

    private var editor: some View {
        NavigationStack {
            TextEditor(text: $text)
                .brandFont(16)
                .foregroundStyle(DesignTokens.Brand.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .background(DesignTokens.Brand.card)
                .focused($focused)
                .navigationTitle("Edit clip")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            // The sweep or a sync may have deleted the clip meanwhile.
                            if !item.isGone { item.saveEdit(text, in: modelContext) }
                            dismiss()
                        }
                        .disabled(text.isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
    }
}
