import Foundation
import SwiftData

/// Lightweight clip for the keyboard: no `rawData`, so memory stays small in the extension.
struct KeyboardClip: Identifiable, Equatable {
    let id: UUID
    let contentType: ContentType
    let preview: String
    let thumbnail: Data?
    let isPinned: Bool
    let copiedAt: Date
    let textByteCount: Int
    let sourceAppName: String?
    /// The keyboard's own capture of the current pasteboard, not yet in the store. Shows "Clipboard" for its meta line.
    var isClipboard = false
    /// A link shown by its page title: the host, for the line under it. Nil otherwise.
    var linkHost: String? = nil
}

extension KeyboardClip {
    /// Same rule as the app's `ClipRow`: link clips, and text clips that are one bare http(s) URL.
    var linkParts: (host: String, rest: String)? {
        switch contentType {
        case .url: LinkParts.split(preview)
        case .plainText, .richText, .html: LinkParts.bareLink(preview)
        default: nil
        }
    }

    /// One line of text for the widget's compact layouts. A link shown by its page title reads "title · host".
    var summary: String {
        if contentType == .image { return String(localized: "Image") }
        if let linkHost { return preview + " \u{00b7} " + linkHost }
        if let parts = linkParts { return parts.host + parts.rest }
        return preview
    }
}

/// A pinboard chip in the keyboard header.
struct KeyboardBoard: Identifiable, Equatable {
    let id: UUID
    let name: String
    let colorIndex: Int
}

enum KeyboardFeed {
    enum Mode: Equatable { case recent, pinned, pinboard(UUID) }
    static let limit = 60, previewLimit = 300

    /// `linkTitles`: a link shows its fetched page title in place of the URL, never its image (memory).
    @MainActor
    static func items(in context: ModelContext, mode: Mode, limit: Int = limit,
                      linkTitles: Bool = LinkPreviewPlan.isEnabled) throws -> [KeyboardClip] {
        // File clips can't be typed or pasted from the keyboard (or copied from the widget): a Mac path, or files.
        // Secrets never show in the keyboard or the widget.
        let fileRaw = ContentType.fileURL.rawValue, filesRaw = ContentType.files.rawValue
        let predicate: Predicate<ClipboardItem>
        switch mode {
        case .recent:
            predicate = #Predicate { $0.contentTypeRaw != fileRaw && $0.contentTypeRaw != filesRaw && $0.isSensitive == false }
        case .pinned:
            predicate = #Predicate {
                $0.contentTypeRaw != fileRaw && $0.contentTypeRaw != filesRaw && $0.isPinned == true && $0.isSensitive == false
            }
        case .pinboard(let boardID):
            // The entries in their own order, then only the card fields of their clips: following `clipboardItem`
            // would load each clip whole. A clip's id is read from the relationship without loading the clip.
            let entries = try context.fetch(FetchDescriptor<PinboardEntry>(
                predicate: #Predicate { $0.pinboard?.id == boardID }, sortBy: [SortDescriptor(\.displayOrder)]))
            let ids = entries.compactMap { $0.clipboardItem?.persistentModelID }
            let byID = Dictionary(try context.fetch(cardFields(#Predicate {
                ids.contains($0.persistentModelID)
                    && $0.contentTypeRaw != fileRaw && $0.contentTypeRaw != filesRaw && $0.isSensitive == false
            })).map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }.prefix(limit).map { clip($0, linkTitles: linkTitles) }
        }
        var descriptor = cardFields(predicate)
        descriptor.sortBy = [SortDescriptor(\.copiedAt, order: .reverse)]
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map { clip($0, linkTitles: linkTitles) }
    }

    /// What a card shows, never `rawData` nor `linkImageData`: small blobs are stored inline, and would load with the row.
    private static func cardFields(_ predicate: Predicate<ClipboardItem>) -> FetchDescriptor<ClipboardItem> {
        var descriptor = FetchDescriptor<ClipboardItem>(predicate: predicate)
        descriptor.propertiesToFetch = [\.id, \.contentTypeRaw, \.textContent, \.thumbnailData, \.isPinned, \.copiedAt,
                                        \.sourceAppName, \.sourceAppBundleId, \.isSensitive, \.linkTitle]
        return descriptor
    }

    @MainActor
    static func boards(in context: ModelContext) throws -> [KeyboardBoard] {
        try context.fetch(FetchDescriptor<Pinboard>(sortBy: [SortDescriptor(\.displayOrder)]))
            .map { KeyboardBoard(id: $0.id, name: $0.name, colorIndex: PinboardDot.index(for: $0.id)) }
    }

    /// The first card in Recent for a copy the keyboard just captured. The inbox drain stores it when the app next opens.
    /// A secret shows masked; tapping it still inserts the copy itself.
    static func clipboardCard(_ clip: CapturedClip, now: Date, protects: Bool = SecretDetector.isProtecting) -> KeyboardClip {
        let type = clip.contentType
        let secret = SecretDetector.flags(clip.textContent, type: type, protects: protects)
            ? clip.textContent.map { SecretDetector.mask($0) } : nil
        return KeyboardClip(
            id: UUID(), contentType: type, preview: secret ?? preview(type, clip.textContent),
            // ImageIO, so the full image is never decoded in the keyboard.
            thumbnail: type == .image ? Thumbnail.png(from: clip.rawData) : nil,
            isPinned: false, copiedAt: now, textByteCount: clip.textContent?.utf8.count ?? 0,
            sourceAppName: nil, isClipboard: true)
    }

    private static func clip(_ item: ClipboardItem, linkTitles: Bool) -> KeyboardClip {
        let type = item.contentType
        let text = item.textContent
        let title = linkTitles ? item.linkPreviewTitle : nil
        return KeyboardClip(
            id: item.id, contentType: type, preview: title ?? preview(type, text),
            thumbnail: type == .image ? item.thumbnailData : nil,
            isPinned: item.isPinned, copiedAt: item.copiedAt, textByteCount: text?.utf8.count ?? 0,
            sourceAppName: item.sourceAppName, linkHost: title == nil ? nil : text.flatMap(LinkParts.split)?.host)
    }

    /// "Insert as…" for one card, worked out when it is long-pressed, never for the whole feed. `text` is the clip's
    /// whole text, fetched only for a text clip short enough to insert: a longer one is copied instead.
    static func menu(for clip: KeyboardClip, text: @autoclosure () -> String?) -> [TextTransform] {
        guard TextTransform.textTypes.contains(clip.contentType), clip.textByteCount <= PasteAction.insertByteLimit,
              let text = text() else { return [] }
        return TextTransform.applicable(to: text, type: clip.contentType)
    }

    private static func preview(_ type: ContentType, _ text: String?) -> String {
        switch type {
        case .image: ""
        case .url, .color: text ?? ""
        // Cut before trimming so a multi-MB clip is never copied whole.
        default: String((text ?? "").prefix(600).trimmingCharacters(in: .whitespacesAndNewlines).prefix(previewLimit))
        }
    }
}
