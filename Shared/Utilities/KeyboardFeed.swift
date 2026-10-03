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

    @MainActor
    static func items(in context: ModelContext, mode: Mode, limit: Int = limit) throws -> [KeyboardClip] {
        let fileRaw = ContentType.fileURL.rawValue
        let predicate: Predicate<ClipboardItem>
        switch mode {
        case .recent: predicate = #Predicate { $0.contentTypeRaw != fileRaw }
        case .pinned: predicate = #Predicate { $0.contentTypeRaw != fileRaw && $0.isPinned == true }
        case .pinboard(let boardID):
            // A board has few entries; order them in memory by the entry's own `displayOrder`.
            var boardFetch = FetchDescriptor<Pinboard>(predicate: #Predicate { $0.id == boardID })
            boardFetch.fetchLimit = 1
            guard let board = try context.fetch(boardFetch).first else { return [] }
            return board.entries.sorted { $0.displayOrder < $1.displayOrder }
                .compactMap(\.clipboardItem)
                .filter { $0.contentType != .fileURL }
                .prefix(limit).map(clip)
        }
        var descriptor = FetchDescriptor<ClipboardItem>(
            predicate: predicate, sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor).map(clip)
    }

    @MainActor
    static func boards(in context: ModelContext) throws -> [KeyboardBoard] {
        try context.fetch(FetchDescriptor<Pinboard>(sortBy: [SortDescriptor(\.displayOrder)]))
            .map { KeyboardBoard(id: $0.id, name: $0.name, colorIndex: PinboardDot.index(for: $0.id)) }
    }

    private static func clip(_ item: ClipboardItem) -> KeyboardClip {
        let type = item.contentType
        let text = item.textContent
        let preview: String
        switch type {
        case .image: preview = ""
        case .url, .color: preview = text ?? ""
        // Cut before trimming so a multi-MB clip is never copied whole.
        default: preview = String((text ?? "").prefix(600).trimmingCharacters(in: .whitespacesAndNewlines).prefix(previewLimit))
        }
        return KeyboardClip(
            id: item.id, contentType: type, preview: preview,
            thumbnail: type == .image ? item.thumbnailData : nil,
            isPinned: item.isPinned, copiedAt: item.copiedAt, textByteCount: text?.utf8.count ?? 0,
            sourceAppName: item.sourceAppName)
    }
}
