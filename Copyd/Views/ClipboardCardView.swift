import SwiftUI
import SwiftData
import ImageIO

struct ClipboardCardView: View {
    let item: ClipboardItem
    var isSelected: Bool = false
    var searchText: String = ""
    var pinboards: [Pinboard] = []
    var quickPasteNumber: Int? = nil
    /// Position in the multi-selection, shown as a badge.
    var selectionNumber: Int? = nil
    /// Shown first in the History row as a likely next paste: a "Suggested" chip replaces the type label.
    var isSuggested: Bool = false
    var enableDrag: Bool = true
    var showsManagementMenu: Bool = true
    let onSelect: (ClipboardItem) -> Void
    let onPaste: (ClipboardItem) -> Void
    var onDelete: (() -> Void)? = nil
    var onRemoveFromPinboard: (() -> Void)? = nil
    /// ⌘-click and ⇧-click pick cards for a joined paste instead of pasting this one.
    var onCommandClick: (() -> Void)? = nil
    var onShiftClick: (() -> Void)? = nil

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var imageDimensions: CGSize?

    var body: some View {
        if item.isDeleted || item.modelContext == nil {
            EmptyView()
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        cardSurface
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(perform: handleTap)
        .optionalDrag(enabled: enableDrag) {
            appState.draggedClipboardItemID = item.id
            return item.dragProvider()
        } preview: {
            dragPreview
        }
        .optionalContextMenu(enabled: hasMenu) {
            menuItems
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Card name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                item.userTitle = trimmed.isEmpty ? nil : trimmed
                try? modelContext.save()
            }
        }
    }

    private var hasMenu: Bool {
        showsManagementMenu || onRemoveFromPinboard != nil
    }

    @ViewBuilder
    private var menuItems: some View {
        if PasteService.supportsPlainText(item) {
            Button("Paste with Formatting") { appState.paste(item, asPlainText: false) }
            Button("Paste as Plain Text") { appState.paste(item, asPlainText: true) }
        } else {
            Button("Paste") { onPaste(item) }
        }
        if showsManagementMenu {
            Divider()
            Button("Rename") {
                renameText = item.userTitle ?? ""
                isRenaming = true
            }
            if !pinboards.isEmpty {
                Menu("Add to Pinboard") {
                    ForEach(pinboards) { pinboard in
                        let alreadyAdded = pinboard.entries.contains { $0.clipboardItem?.id == item.id }
                        Button {
                            addToPinboard(pinboard)
                        } label: {
                            if alreadyAdded {
                                Label(pinboard.name, systemImage: "checkmark")
                            } else {
                                Text(pinboard.name)
                            }
                        }
                        .disabled(alreadyAdded)
                    }
                }
            }
            Divider()
            Button("Delete Clip", role: .destructive) {
                deleteItem()
                onDelete?()
            }
        }
        if let onRemoveFromPinboard {
            Divider()
            Button("Remove from Pinboard", role: .destructive) {
                onRemoveFromPinboard()
            }
        }
    }

    private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius, style: .continuous)
        return VStack(spacing: 8) {
            headerView

            contentView

            footerView
        }
        .padding(DesignTokens.Card.padding)
        .frame(width: DesignTokens.Card.width, height: DesignTokens.Card.height)
        .background(DesignTokens.Brand.card)
        .clipShape(shape)
        .contentShape(shape)
        .overlay(
            shape.strokeBorder(
                isSelected ? DesignTokens.Brand.butter : DesignTokens.Brand.line,
                lineWidth: 1
            )
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius + DesignTokens.Card.ringWidth, style: .continuous)
                    .strokeBorder(DesignTokens.Brand.butter, lineWidth: DesignTokens.Card.ringWidth)
                    .padding(-DesignTokens.Card.ringWidth)
            }
        }
        .overlay(alignment: .topTrailing) { numberBadge }
        .shadow(
            color: .black.opacity(isHovered ? DesignTokens.Selection.hoverShadowOpacity : DesignTokens.Selection.defaultShadowOpacity),
            radius: isHovered ? DesignTokens.Selection.hoverShadowRadius : DesignTokens.Selection.defaultShadowRadius,
            y: isHovered ? 5 : 2
        )
        .scaleEffect(isHovered ? DesignTokens.Selection.hoverScale : 1.0)
        .offset(y: isHovered && !isSelected ? DesignTokens.Selection.hoverLift : 0)
        .brightness(isHovered && !isSelected ? 0.04 : 0)
        .zIndex(isHovered ? 1 : 0)
        .animation(.spring(response: 0.28, dampingFraction: 0.75), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(accessibilityDescription)
        .task(id: item.id) {
            imageDimensions = item.contentType == .image ? Self.pixelSize(of: item.rawData) : nil
        }
    }

    /// The selection number wins over the ⌘-number hint, which only shows while ⌘ is held.
    @ViewBuilder
    private var numberBadge: some View {
        if let selectionNumber {
            Text(verbatim: "\(selectionNumber)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(DesignTokens.Brand.onButter)
                .frame(minWidth: 20, minHeight: 20)
                .background(DesignTokens.Brand.butter, in: Circle())
                .overlay(Circle().strokeBorder(DesignTokens.Brand.card, lineWidth: 1.5))
                .offset(x: 6, y: -6)
                .accessibilityHidden(true)
        } else if let number = quickPasteNumber, appState.isCommandHeld,
           let hint = QuickPasteShortcut.hint(number: number) {
            Text(hint)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Brand.onButter)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(DesignTokens.Brand.butter, in: Capsule())
                .offset(x: 6, y: -6)
                .accessibilityHidden(true)
        }
    }

    private var accessibilitySummary: String {
        switch item.contentType {
        case .image:
            return imageDimensions.map { String(localized: "image \(Int($0.width)) × \(Int($0.height))") } ?? String(localized: "image")
        case .url:
            let text = item.textContent ?? ""
            return URL(string: text)?.host ?? text
        case .color, .fileURL, .files:
            return item.textContent ?? ""
        default:
            return String((item.textContent ?? "").prefix(60))
        }
    }

    private var accessibilityDescription: String {
        let app = item.sourceAppName ?? String(localized: "unknown app")
        var label = String(localized: "\(item.contentType.displayName), \(accessibilitySummary), from \(app)")
        if isSuggested {
            label = "\(String(localized: "Suggested")), \(label)"
        }
        if let number = quickPasteNumber {
            label += String(localized: ", Command \(number + 1) to paste")
        }
        return label
    }

    private var dragPreview: some View {
        cardSurface
            .opacity(0.36)
            .scaleEffect(0.94)
    }

    private func handleTap() {
        switch NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]) {
        case .command where onCommandClick != nil: onCommandClick?(); return
        case .shift where onShiftClick != nil: onShiftClick?(); return
        default: break
        }
        onSelect(item)
        onPaste(item)
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: item.contentType.systemImage)
                .foregroundStyle(DesignTokens.typeTint(for: item.contentType, itemColor: item.textContent))
            if isSuggested {
                Text("Suggested")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignTokens.Brand.onButter)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DesignTokens.Brand.butter, in: Capsule())
            } else {
                Text(item.userTitle ?? item.contentType.displayName)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(RelativeTimeFormatter.string(for: item.copiedAt))
                .lineLimit(1)

            if let bundleId = item.sourceAppBundleId {
                Image(nsImage: AppIconProvider.icon(for: bundleId, size: 40))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(DesignTokens.Brand.ink2)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer View

    private var footerView: some View {
        HStack(spacing: 6) {
            Group {
                if item.contentType == .color {
                    Text(footerInfo).font(.system(size: 11).monospaced())
                } else {
                    Text(footerInfo).font(.system(size: 11))
                }
            }
            .foregroundStyle(DesignTokens.Brand.ink2)
            .lineLimit(1)

            Spacer()

            if hasMenu {
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.Brand.ink2)
                        .opacity(isHovered || isSelected ? 0.9 : 0.5)
                        .frame(width: 24, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
            }
        }
    }

    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    private var footerInfo: String {
        switch item.contentType {
        case .plainText, .richText, .html, .unknown:
            let count = item.textContent?.count ?? 0
            if count >= 1000 {
                let thousands = String(format: "%.1f", Double(count) / 1000)
                return String(localized: "\(thousands)K chars")
            }
            return String(localized: "\(count) chars")
        case .url:
            return item.sourceAppName ?? String(localized: "Link")
        case .fileURL:
            return String(localized: "Stays on this Mac")
        case .files:
            return item.filesSizeText
        case .image:
            let size = ByteCountFormatter.string(fromByteCount: Int64(item.rawData.count), countStyle: .file)
            guard let dims = imageDimensions else { return size }
            return "\(Int(dims.width)) × \(Int(dims.height)) · \(size)"
        case .color:
            return item.textContent ?? ""
        }
    }

    // MARK: - Content

    private var contentView: some View {
        cardContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.wellRadius, style: .continuous))
    }

    @ViewBuilder
    private var cardContent: some View {
        switch item.contentType {
        case .plainText, .richText, .html:
            TextCardContent(item: item, searchText: searchText)
        case .image:
            ImageCardContent(item: item)
        case .url:
            LinkCardContent(item: item, searchText: searchText)
        case .fileURL, .files:
            FileCardContent(item: item, searchText: searchText)
        case .color:
            ColorCardContent(item: item)
        case .unknown:
            TextCardContent(item: item, searchText: searchText)
        }
    }

    private func addToPinboard(_ pinboard: Pinboard) {
        let nextOrder = (pinboard.entries.map(\.displayOrder).max() ?? -1) + 1
        let entry = PinboardEntry(clipboardItem: item, pinboard: pinboard, displayOrder: nextOrder)
        modelContext.insert(entry)
        item.isPinned = true
        try? modelContext.save()
    }

    private func deleteItem() {
        let itemId = item.id
        let descriptor = FetchDescriptor<PinboardEntry>(
            predicate: #Predicate { $0.clipboardItem?.id == itemId }
        )
        if let entries = try? modelContext.fetch(descriptor) {
            for entry in entries {
                modelContext.delete(entry)
            }
        }
        modelContext.delete(item)
        try? modelContext.save()
    }
}

// MARK: - Conditional Drag Modifier

private extension View {
    @ViewBuilder
    func optionalDrag<Preview: View>(
        enabled: Bool,
        provider: @escaping () -> NSItemProvider,
        @ViewBuilder preview: () -> Preview
    ) -> some View {
        if enabled {
            self.onDrag(provider, preview: preview)
        } else {
            self
        }
    }

    @ViewBuilder
    func optionalContextMenu<Content: View>(
        enabled: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if enabled {
            self.contextMenu(menuItems: content)
        } else {
            self
        }
    }
}
