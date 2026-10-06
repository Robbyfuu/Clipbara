import Foundation
import SwiftData

/// The MCP tools over Copyd's store (spec §3). Every read runs on a utility queue in a `ModelContext` of its own. Every
/// fetch filters flagged secrets (`isSensitive == false`) in its predicate, and a clip whose text or OCR text reads as a
/// secret is dropped too, as Spotlight drops it: with "Protect secrets" off nothing is flagged, yet a key never leaves.
struct StoreClipLibrary: ClipLibrary {
    /// Search matches in memory over this many of the newest non-secret clips: SwiftData predicates can't match file
    /// names, which live in the manifest blob.
    static let searchWindow = 2000
    static let previewLength = 200
    static let maxTextBytes = 100 * 1024

    private let container: ModelContainer
    /// The automatic pinboards to list and resolve: none while "Automatic pinboards" is off, as in the panel.
    private let smartBoards: @Sendable () -> [SmartBoard]
    /// Writes plain text to the clipboard. Not skipped by the monitor: Copyd captures it like any copy. Throws a
    /// `ToolError` to refuse, as while Copyd is pasting.
    private let write: @MainActor @Sendable (String) throws -> Void

    init(container: ModelContainer,
         smartBoards: @escaping @Sendable () -> [SmartBoard] = { SmartKinds.isEnabled ? SmartBoard.listed : [] },
         write: @escaping @MainActor @Sendable (String) throws -> Void) {
        self.container = container
        self.smartBoards = smartBoards
        self.write = write
    }

    // MARK: ClipLibrary

    func search(query: String?, type: ClipKind?, board: String?, limit: Int) async throws -> [ClipSummary] {
        let boards = smartBoards()
        let limit = min(limit, MCPTools.maxLimit)
        return try await read { context in
            guard let predicate = try Self.visibleClips(on: board, smartBoards: boards, in: context) else { return [] }
            var fetch = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
            // The whole window even with nothing to match: a clip that reads as a secret is only found out in memory.
            fetch.fetchLimit = Self.searchWindow
            // Never `rawData`, the thumbnail or the link image.
            fetch.propertiesToFetch = [\.id, \.contentTypeRaw, \.textContent, \.sourceAppName, \.copiedAt, \.isPinned,
                                       \.ocrText, \.linkTitle, \.fileManifestData, \.smartKinds]
            var results: [ClipSummary] = []
            for clip in try context.fetch(fetch) {
                guard results.count < limit else { break }
                let kind = Self.kind(of: clip)
                guard type == nil || kind == type, query.map({ Self.matches(clip, $0) }) ?? true,
                      !Self.readsAsSecret(clip) else { continue }
                results.append(ClipSummary(id: clip.id, type: kind, preview: Self.preview(of: clip), app: clip.sourceAppName,
                                           copiedAt: clip.copiedAt, pinned: clip.isPinned))
            }
            return results
        }
    }

    func clip(id: UUID) async throws -> ClipDetail? {
        try await read { context in
            var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id && $0.isSensitive == false })
            fetch.fetchLimit = 1
            fetch.propertiesToFetch = [\.id, \.contentTypeRaw, \.textContent, \.sourceAppName, \.copiedAt, \.ocrText,
                                       \.linkTitle, \.fileManifestData, \.smartKinds]
            guard let clip = try context.fetch(fetch).first, !Self.readsAsSecret(clip) else { return nil }
            let (text, truncated) = Self.capped(clip.contentType == .image ? nil : clip.textContent)
            return ClipDetail(id: clip.id, type: Self.kind(of: clip), text: text, truncated: truncated, app: clip.sourceAppName,
                              copiedAt: clip.copiedAt, linkTitle: clip.linkTitle, ocrText: clip.ocrText,
                              fileNames: Self.fileNames(of: clip))
        }
    }

    func boards() async throws -> [BoardSummary] {
        let boards = smartBoards()
        return try await read { context in
            let hidden = try Self.unflaggedSecrets(in: context)
            let pinboards = try context.fetch(FetchDescriptor<Pinboard>(sortBy: [SortDescriptor(\.displayOrder)]))
            let user = try pinboards.map { board in
                let ids = try Self.clipIDs(on: board.id, in: context).filter { hidden[$0] == nil }
                let count = ids.isEmpty ? 0 : try context.fetchCount(FetchDescriptor<ClipboardItem>(predicate: #Predicate {
                    ids.contains($0.persistentModelID) && $0.isSensitive == false
                }))
                return BoardSummary(id: nil, name: board.name, count: count)
            }
            let smart = try SmartKinds.counts(in: context, boards: boards, includesSecrets: false).compactMap { entry in
                let count = entry.count - hidden.values.filter { SmartKinds.members(of: entry.board, kinds: $0.kinds, topic: $0.topic) }.count
                return count > 0 ? BoardSummary(id: entry.board.rawValue, name: entry.board.title, count: count) : nil
            }
            return user + smart
        }
    }

    /// Checked on the main actor right before writing: a request cancelled meanwhile (the server stopped) writes nothing.
    func copy(text: String) async throws {
        try await MainActor.run {
            try Task.checkCancellation()
            try write(text)
        }
    }

    // MARK: reading

    /// `work` on a utility queue, never the main actor nor a cooperative thread, in a context of its own.
    private func read<T: Sendable>(_ work: @escaping @Sendable (ModelContext) throws -> T) async throws -> T {
        let container = container
        return try await ImageTextQueue.offMain { Result { try work(ModelContext(container)) } }.get()
    }

    /// The non-secret clips on `board`: a user pinboard by name (ignoring case and accents), else a listed smart board
    /// by id. Nil for an unknown or empty board. Every case is its own literal predicate, as `SmartKinds` requires.
    private static func visibleClips(on board: String?, smartBoards: [SmartBoard],
                                     in context: ModelContext) throws -> Predicate<ClipboardItem>? {
        guard let board else { return #Predicate { $0.isSensitive == false } }
        let pinboards = try context.fetch(FetchDescriptor<Pinboard>(sortBy: [SortDescriptor(\.displayOrder)]))
        let named = pinboards.first { $0.name.compare(board, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if let pinboard = named {
            // A `contains` on an empty array is unreliable in a store predicate on macOS 14.
            let ids = try clipIDs(on: pinboard.id, in: context)
            return ids.isEmpty ? nil : #Predicate { ids.contains($0.persistentModelID) && $0.isSensitive == false }
        }
        return smartBoards.first { $0.rawValue == board.lowercased() }
            .map { SmartKinds.predicate(for: $0, includesSecrets: false) }
    }

    /// Unflagged clips that read as secrets, with what places them on smart boards: the counts leave them out, as search
    /// does. ponytail: one detector pass over the whole history per `list_pinboards`; cache it if that call gets hot.
    private static func unflaggedSecrets(in context: ModelContext) throws -> [PersistentIdentifier: (kinds: Int, topic: String?)] {
        var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.isSensitive == false })
        fetch.propertiesToFetch = [\.textContent, \.ocrText, \.smartKinds, \.topicRaw]
        var found: [PersistentIdentifier: (kinds: Int, topic: String?)] = [:]
        try context.enumerate(fetch, batchSize: 200) { clip in
            if readsAsSecret(clip) { found[clip.persistentModelID] = (clip.smartKinds, clip.topicRaw) }
        }
        return found
    }

    /// A pinboard's clips, read from the entries' relationship without loading the clips (as `KeyboardFeed` does).
    private static func clipIDs(on boardID: UUID, in context: ModelContext) throws -> [PersistentIdentifier] {
        try context.fetch(FetchDescriptor<PinboardEntry>(predicate: #Predicate { $0.pinboard?.id == boardID }))
            .compactMap { $0.clipboardItem?.persistentModelID }
    }

    // MARK: fields

    /// A text clip is code when the type boards sorted it so (`SmartKinds`).
    private static func kind(of clip: ClipboardItem) -> ClipKind {
        switch clip.contentType {
        case .url: .link
        case .image: .image
        case .files, .fileURL: .file
        case .color: .color
        case .plainText, .richText, .html, .unknown: clip.smartKinds & SmartBoard.code.bit != 0 ? .code : .text
        }
    }

    /// The text or the OCR text reads as a secret, flagged or not, as `SpotlightPlan` checks it.
    private static func readsAsSecret(_ clip: ClipboardItem) -> Bool {
        [clip.textContent, clip.ocrText].contains { $0.flatMap(SecretDetector.kind(of:)) != nil }
    }

    private static func matches(_ clip: ClipboardItem, _ query: String) -> Bool {
        [clip.textContent, clip.ocrText, clip.linkTitle].contains { $0?.localizedStandardContains(query) == true }
            || fileNames(of: clip).contains { $0.localizedStandardContains(query) }
    }

    /// An image by its OCR text, a link by its page title, anything else by its text; at most `previewLength` characters.
    private static func preview(of clip: ClipboardItem) -> String {
        let text: String? = switch clip.contentType {
        case .image: clip.ocrText
        case .url: clip.linkTitle.flatMap { $0.isEmpty ? nil : $0 } ?? clip.textContent
        default: clip.textContent
        }
        // Cut before trimming, so a multi-MB text is never copied whole.
        return String((text ?? "").prefix(previewLength * 3).trimmingCharacters(in: .whitespacesAndNewlines).prefix(previewLength))
    }

    /// The text cut at the last whole character within `maxTextBytes` of UTF-8, and whether it was cut.
    private static func capped(_ text: String?) -> (String?, Bool) {
        guard let text, text.utf8.count > maxTextBytes else { return (text, false) }
        var bytes = 0
        let end = text.firstIndex { bytes += $0.utf8.count; return bytes > maxTextBytes } ?? text.endIndex
        return (String(text[..<end]), true)
    }

    /// Copied files by their manifest; an older local file link by its name, which is its text.
    private static func fileNames(of clip: ClipboardItem) -> [String] {
        switch clip.contentType {
        case .files: clip.fileManifest?.map(\.name) ?? []
        case .fileURL: clip.textContent.map { [$0] } ?? []
        default: []
        }
    }
}
