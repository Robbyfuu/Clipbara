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
}

enum KeyboardFeed {
    enum Mode { case recent, pinned }
    static let limit = 60, previewLimit = 300

    @MainActor
    static func items(in context: ModelContext, mode: Mode, limit: Int = limit) throws -> [KeyboardClip] {
        let fileRaw = ContentType.fileURL.rawValue
        let predicate: Predicate<ClipboardItem> = mode == .pinned
            ? #Predicate { $0.contentTypeRaw != fileRaw && $0.isPinned == true }
            : #Predicate { $0.contentTypeRaw != fileRaw }
        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: predicate, sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map(clip)
    }

    private static func clip(_ item: ClipboardItem) -> KeyboardClip {
        let type = item.contentType
        let text = item.textContent
        let preview: String
        switch type {
        case .image: preview = ""
        case .url, .color: preview = text ?? ""
        default: preview = String((text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(previewLimit))
        }
        return KeyboardClip(
            id: item.id, contentType: type, preview: preview,
            thumbnail: type == .image ? item.thumbnailData : nil,
            isPinned: item.isPinned, copiedAt: item.copiedAt, textByteCount: text?.utf8.count ?? 0)
    }
}
