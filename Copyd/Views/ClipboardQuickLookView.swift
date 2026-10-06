import SwiftUI
import AppKit

struct ClipboardQuickLookView: View {
    let item: ClipboardItem
    let shelfHeight: CGFloat
    let onClose: () -> Void
    let onPaste: () -> Void
    @ObservedObject var zoom: ImageZoomController

    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedImage: NSImage?
    @State private var imageMetadata: (width: Int, height: Int)?
    @State private var cachedCharCount: Int = 0
    @State private var cachedIsCodeLike: Bool = false
    @State private var cachedCodeRanges: [(range: NSRange, kind: CodeTokenKind)] = []
    /// The text formatted when it is Markdown, not code and not a secret.
    @State private var cachedMarkdown: NSAttributedString?
    /// A secret shows its mask until Show. Every item change, ←/→ included, hides it again.
    @State private var isRevealed = false
    @AppStorage(LinkPreviewPlan.enabledDefaultsKey) private var linkPreviewsOn = true

    init(
        item: ClipboardItem,
        shelfHeight: CGFloat,
        zoom: ImageZoomController,
        onClose: @escaping () -> Void,
        onPaste: @escaping () -> Void
    ) {
        self.item = item
        self.shelfHeight = shelfHeight
        self.zoom = zoom
        self.onClose = onClose
        self.onPaste = onPaste
        // Decode up front so the bubble is sized to the image on the very first frame
        // instead of flashing at full size and then shrinking.
        _cachedImage = State(initialValue: item.contentType == .image ? NSImage(data: item.rawData) : nil)
    }

    var body: some View {
        // The sweep or a remote delete can remove the clip while it shows; PanelController then closes Quick Look.
        if item.isGone {
            EmptyView()
        } else {
            quickLook
        }
    }

    private var quickLook: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(colorScheme == .dark ? 0.26 : 0.16)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)

                quickLookBubble(in: geo.size)
                    .padding(.bottom, shelfHeight + 18)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        // A link's preview may land while Quick Look shows it: the fetch marks the link done, which runs this again.
        .task(id: "\(item.id) \(item.linkPreviewDone)") {
            isRevealed = false
            if item.contentType == .image {
                let image = cachedImage ?? NSImage(data: item.rawData)
                cachedImage = image
                if let rep = image?.representations.first {
                    imageMetadata = (rep.pixelsWide, rep.pixelsHigh)
                }
                cachedCharCount = 0
                cachedIsCodeLike = false
                cachedCodeRanges = []
                cachedMarkdown = nil
            } else {
                // A link's fetched image; the bubble keeps its fixed size, so `imageMetadata` stays nil.
                cachedImage = item.contentType == .url ? item.linkImageData.flatMap(NSImage.init(data:)) : nil
                imageMetadata = nil

                let text = item.textContent ?? ""
                cachedCharCount = text.count
                cachedIsCodeLike = CodeDetector.isCode(text)
                // Worked out once per clip here, never per body. Quick Look scrolls, so it colors past the cards' 2 KB.
                cachedCodeRanges = cachedIsCodeLike
                    ? SyntaxHighlighter.tokens(in: text, limit: Self.codeColorLimit).map { (NSRange($0.range, in: text), $0.kind) }
                    : []
                // Code wins over Markdown. A longer text shows plain: parsing it whole here would hold up the panel.
                cachedMarkdown = !cachedIsCodeLike && !item.isSensitive && text.utf8.count <= Self.markdownLimit
                    && [.plainText, .richText, .html].contains(item.contentType) && MarkdownDetector.isMarkdown(text)
                    ? MarkdownConverter.attributed(fromMarkdown: text, baseSize: 14) : nil
            }
        }
    }

    private static let toolbarHeight: CGFloat = 48
    private static let footerHeight: CGFloat = 36
    private static let minImageBubbleWidth: CGFloat = 520
    private static let minImageBubbleHeight: CGFloat = 300
    /// The recognized text under an image: selectable, scrolling past this height.
    private static let imageTextHeight: CGFloat = 120
    /// Characters of code that get colors: about 1 ms of highlighting, bounded however long the clip is.
    private static let codeColorLimit = 20_000
    /// Bytes of Markdown shown formatted: parsed once per clip, in a few milliseconds.
    private static let markdownLimit = 64_000

    /// Text and other types keep the large fixed bubble. Images get a bubble shaped
    /// like the image at its fitted size, so there is no dead checkerboard around it.
    private func bubbleSize(in size: CGSize) -> CGSize {
        let maxWidth = min(size.width * 0.72, 1080)
        let availableHeight = max(size.height - shelfHeight - 68, 360)
        let maxHeight = min(max(availableHeight * 0.86, 360), 720)

        guard item.contentType == .image,
              let image = cachedImage,
              image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }

        let chrome = Self.toolbarHeight + Self.footerHeight + 2 + (item.recognizedText == nil ? 0 : Self.imageTextHeight + 1)
        let margin = ZoomingImageScrollView.fitMargin * 2
        let maxContent = CGSize(width: maxWidth - margin, height: maxHeight - chrome - margin)
        let scale = min(1, maxContent.width / image.size.width, maxContent.height / image.size.height)
        let width = image.size.width * scale + margin
        let height = image.size.height * scale + margin + chrome
        return CGSize(
            width: min(max(width, Self.minImageBubbleWidth), maxWidth),
            height: min(max(height, Self.minImageBubbleHeight), maxHeight)
        )
    }

    private func quickLookBubble(in size: CGSize) -> some View {
        let bubble = bubbleSize(in: size)

        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider().opacity(0.35)
                content
                Divider().opacity(0.35)
                footer
            }
            .frame(width: bubble.width, height: bubble.height)
            .background(.regularMaterial)
            .background(bubbleTint)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.22), radius: 28, y: 10)
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

            BubblePointer()
                .fill(bubblePointerFill)
                .frame(width: 32, height: 14)
                .overlay(
                    BubblePointer()
                        .stroke(borderColor, lineWidth: 0.75)
                )
                .offset(y: -1)
        }
        .environment(\.colorScheme, .dark)
        .onTapGesture { }
    }

    private var toolbar: some View {
        let tint = DesignTokens.typeTint(for: item.contentType, itemColor: item.textContent)

        return HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help("Close")

            HStack(spacing: 6) {
                Image(systemName: item.contentType.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(item.userTitle ?? item.contentType.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)

            if let appName = item.sourceAppName {
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(appName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if item.contentType == .image, cachedImage != nil {
                zoomControls
            }

            if let bundleId = item.sourceAppBundleId {
                Image(nsImage: AppIconProvider.icon(for: bundleId, size: 24))
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            Button(action: onPaste) {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                    Text("Paste")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.accentColor.opacity(0.13))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.toolbarHeight)
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            zoomButton(systemImage: "minus", help: "Zoom Out (⌘-)", enabled: zoom.canZoomOut) {
                zoom.perform(.zoomOut)
            }

            Button {
                zoom.toggleFitAndActualSize()
            } label: {
                Text(zoom.isFitted ? String(localized: "Fit") : "\(Int((zoom.magnification * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 44, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(zoom.isFitted
                ? String(localized: "Actual Size (double-click image)")
                : String(localized: "Fit to Window (⌘0)"))

            zoomButton(systemImage: "plus", help: "Zoom In (⌘+)", enabled: zoom.canZoomIn) {
                zoom.perform(.zoomIn)
            }
        }
        .background(toolbarButtonBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func zoomButton(systemImage: String, help: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .help(help)
    }

    @ViewBuilder
    private var content: some View {
        if let mask = item.secretMask, !isRevealed {
            maskedContent(mask)
        } else {
            switch item.contentType {
            case .plainText, .richText, .html, .unknown:
                textContent
            case .image:
                imageContent
            case .url:
                urlContent
            case .fileURL, .files:
                fileContent
            case .color:
                colorContent
            }
        }
    }

    private func maskedContent(_ mask: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(mask)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
            Button("Show") { isRevealed = true }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(contentBackground)
    }

    private var textContent: some View {
        SelectableTextView(
            text: item.textContent ?? "...",
            isMonospaced: cachedIsCodeLike,
            fontSize: 14,
            lineSpacing: 5,
            codeRanges: cachedCodeRanges,
            formatted: cachedMarkdown
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(contentBackground)
    }

    private var imageContent: some View {
        VStack(spacing: 0) {
            Group {
                if let cachedImage {
                    ZoomableImageView(image: cachedImage, controller: zoom)
                } else {
                    placeholder(systemImage: "photo", text: "Unable to load image")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // Images are never secrets, so their text is never masked.
            if let text = item.recognizedText {
                Divider().opacity(0.35)
                SelectableTextView(text: text, fontSize: 13, lineSpacing: 3,
                                   contentInsets: NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.imageTextHeight)
            }
        }
        .background(contentBackground)
    }

    private var urlContent: some View {
        let urlString = item.textContent ?? ""
        let url = URL(string: urlString)
        let domain = url?.host ?? urlString
        let title = linkPreviewsOn ? item.linkPreviewTitle : nil

        return VStack(alignment: .leading, spacing: 16) {
            if linkPreviewsOn, let cachedImage {
                Image(nsImage: cachedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 14) {
                iconTile(systemImage: "globe", tint: .teal)

                VStack(alignment: .leading, spacing: 5) {
                    if let title {
                        Text(title)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    Text(domain)
                        .font(.system(size: title == nil ? 20 : 14, weight: title == nil ? .semibold : .regular))
                        .foregroundStyle(title == nil ? .primary : .secondary)
                        .lineLimit(1)

                    Text(urlString)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(contentBackground)
    }

    private var fileContent: some View {
        let fileIcon = item.fileIcon
        let fileName = item.textContent?.components(separatedBy: "/").last ?? String(localized: "File")

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.orange.opacity(0.10))
                        .frame(width: 64, height: 64)
                    Image(nsImage: fileIcon)
                        .resizable()
                        .frame(width: 46, height: 46)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(fileName)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(2)

                    Text(item.textContent ?? "")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(contentBackground)
    }

    private var colorContent: some View {
        let color = Color(hex: item.textContent ?? "") ?? .gray

        return VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(item.textContent ?? String(localized: "Color"))
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(contentBackground)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(primaryMetadata)

            Text("·")
                .foregroundStyle(.quaternary)

            Text(RelativeTimeFormatter.string(for: item.copiedAt))

            Spacer()

            Text(item.contentType.displayName)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: Self.footerHeight)
    }

    private func placeholder(systemImage: String, text: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    private func iconTile(systemImage: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.12))
                .frame(width: 64, height: 64)
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(tint)
        }
    }

    private var primaryMetadata: String {
        switch item.contentType {
        case .plainText, .richText, .html, .unknown:
            return String(localized: "\(cachedCharCount) chars")
        case .image:
            if let imageMetadata {
                return "\(imageMetadata.width) x \(imageMetadata.height) · \(fileSizeText)"
            }
            return fileSizeText
        case .url:
            return String(localized: "URL")
        case .fileURL:
            return String(localized: "File")
        case .files:
            return item.filesSizeText
        case .color:
            return item.textContent ?? String(localized: "Color")
        }
    }

    private var fileSizeText: String {
        let kb = item.rawData.count / 1024
        if kb >= 1024 {
            return "\(String(format: "%.1f", Double(kb) / 1024))MB"
        }
        return "\(kb)KB"
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.11) : Color.white.opacity(0.10)
    }

    private var toolbarButtonBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.08)
    }

    private var contentBackground: Color {
        colorScheme == .dark ? Color.black.opacity(0.08) : Color.black.opacity(0.18)
    }

    private var bubbleTint: Color {
        colorScheme == .dark ? Color.black.opacity(0.06) : Color.black.opacity(0.24)
    }

    private var bubblePointerFill: Color {
        colorScheme == .dark ? Color(white: 0.16) : Color(white: 0.30)
    }
}

private struct BubblePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
