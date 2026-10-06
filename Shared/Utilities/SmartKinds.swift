import Foundation
import SwiftData

/// An automatic pinboard: a read-only view of History, never a `Pinboard` entity, and never synced. The type boards come
/// first, in the spec's order; the topic boards (Apple Intelligence) follow.
enum SmartBoard: String, CaseIterable, Hashable, Sendable {
    case links, code, addresses, contacts, images, colors, files
    case work, shopping, travel, finance, study, social, personal

    /// The type boards, sorted by `SmartKinds.classify`, in display order.
    static let types: [SmartBoard] = [.links, .code, .addresses, .contacts, .images, .colors, .files]

    var isTopic: Bool { !Self.types.contains(self) }

    /// A type board's bit in `ClipboardItem.smartKinds`; 0 for a topic board.
    var bit: Int { Self.types.firstIndex(of: self).map { 1 << $0 } ?? 0 }

    var title: String { title(bundle: .main) }

    /// `bundle` holds the catalog; tests pass one language's `.lproj`.
    func title(bundle: Bundle) -> String {
        switch self {
        case .links: String(localized: "Links", bundle: bundle)
        case .code: String(localized: "Code", bundle: bundle)
        case .addresses: String(localized: "Addresses", bundle: bundle)
        case .contacts: String(localized: "Phones & Emails", bundle: bundle)
        case .images: String(localized: "Images", bundle: bundle)
        case .colors: String(localized: "Colors", bundle: bundle)
        case .files: String(localized: "Files", bundle: bundle)
        case .work: String(localized: "Work", bundle: bundle)
        case .shopping: String(localized: "Shopping", bundle: bundle)
        case .travel: String(localized: "Travel", bundle: bundle)
        case .finance: String(localized: "Finance", bundle: bundle)
        case .study: String(localized: "Study", bundle: bundle)
        case .social: String(localized: "Social", bundle: bundle)
        case .personal: String(localized: "Personal", bundle: bundle)
        }
    }
}

/// Sorts a clip into the type boards. Pure: the fill pass (`SmartKindsQueue`) stores the result in the clip's local-only
/// `smartKinds`, with `version` in `smartKindsVersion`.
enum SmartKinds {
    /// Bump to sort every clip again, after a change to `classify`. 2: secrets are in no board.
    static let version = 2
    /// Only the start of a long text is scanned.
    static let sampleBytes = 4096
    /// The fill pass sorts this many of the newest clips, `batchSize` at a time.
    static let window = 1000
    static let batchSize = 50

    /// "Automatic pinboards". The App Group on iOS, like the secret settings, so the keyboard reads it too.
    static let enabledDefaultsKey = "smartBoardsEnabled"
    static var isEnabled: Bool { SecretDetector.settings.object(forKey: enabledDefaultsKey) as? Bool ?? true }

    /// The bitmask of type boards (`SmartBoard.bit`) a clip belongs to. Text is scanned by `CodeDetector` and
    /// NSDataDetector, from its first `sampleBytes` only.
    static func classify(contentType: ContentType, text: String?) -> Int {
        switch contentType {
        case .url: return SmartBoard.links.bit
        case .image: return SmartBoard.images.bit
        case .color: return SmartBoard.colors.bit
        case .files, .fileURL: return SmartBoard.files.bit
        case .plainText, .richText, .html: break
        case .unknown: return 0
        }
        guard let text else { return 0 }
        let sample = String(decoding: text.utf8.prefix(sampleBytes), as: UTF8.self)
        // A text cut at `sampleBytes` may look like one link; the whole text is not.
        if text.utf8.count <= sampleBytes, LinkParts.bareLink(sample) != nil { return SmartBoard.links.bit }
        var kinds = CodeDetector.isCode(sample) ? SmartBoard.code.bit : 0
        for match in detector?.matches(in: sample, range: NSRange(sample.startIndex..., in: sample)) ?? [] {
            switch match.resultType {
            case .address: kinds |= SmartBoard.addresses.bit
            case .phoneNumber: kinds |= SmartBoard.contacts.bit
            case .link where match.url?.scheme?.lowercased() == "mailto": kinds |= SmartBoard.contacts.bit
            default: break
            }
        }
        return kinds
    }

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.address.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.link.rawValue)

    /// Whether a clip with these `kinds` and `topic` shows in `board`.
    static func members(of board: SmartBoard, kinds: Int, topic: String?) -> Bool {
        board.isTopic ? topic == board.rawValue : kinds & board.bit != 0
    }

    /// The newest clips not sorted by this `version` yet, at most `limit`, among the `window` newest clips.
    static func nextBatch(clips: [(id: UUID, version: Int, copiedAt: Date)], version: Int = version,
                          limit: Int = batchSize, window: Int = window) -> [UUID] {
        clips.sorted { $0.copiedAt > $1.copiedAt }.prefix(window)
            .filter { $0.version != version }.prefix(limit).map(\.id)
    }

    // MARK: In the store

    /// Every `smartKinds` value holding a type board's bit, for an in-store `masks.contains($0.smartKinds)`: SwiftData
    /// has no bitwise or division operator in a predicate. 64 values for 7 type boards. Empty for a topic board, which
    /// matches its topic instead (`predicate(for:)`).
    static func masks(for board: SmartBoard) -> [Int] {
        board.isTopic ? [] : (0..<(1 << SmartBoard.types.count)).filter { $0 & board.bit != 0 }
    }

    /// A board's clips, matched in the store, so a count or a list never loads every clip: a type board by its masks,
    /// a topic board by `topicRaw`. `excluding`: types the caller's list leaves out. `includesSecrets`: false where
    /// secrets never show (the keyboard). Each case is its own literal predicate: a captured Bool, or a `contains` on an
    /// empty array, is unreliable in a store predicate on macOS 14 and iOS 17.
    static func predicate(for board: SmartBoard, excluding types: [ContentType] = [],
                          includesSecrets: Bool = true) -> Predicate<ClipboardItem> {
        let excluded = types.map(\.rawValue)
        if board.isTopic {
            let topic: String? = board.rawValue
            switch (excluded.isEmpty, includesSecrets) {
            case (true, true): return #Predicate { $0.topicRaw == topic }
            case (true, false): return #Predicate { $0.topicRaw == topic && $0.isSensitive == false }
            case (false, true): return #Predicate { $0.topicRaw == topic && !excluded.contains($0.contentTypeRaw) }
            case (false, false):
                return #Predicate {
                    $0.topicRaw == topic && $0.isSensitive == false && !excluded.contains($0.contentTypeRaw)
                }
            }
        }
        let masks = masks(for: board)
        switch (excluded.isEmpty, includesSecrets) {
        case (true, true): return #Predicate { masks.contains($0.smartKinds) }
        case (true, false): return #Predicate { masks.contains($0.smartKinds) && $0.isSensitive == false }
        case (false, true): return #Predicate { masks.contains($0.smartKinds) && !excluded.contains($0.contentTypeRaw) }
        case (false, false):
            return #Predicate {
                masks.contains($0.smartKinds) && $0.isSensitive == false && !excluded.contains($0.contentTypeRaw)
            }
        }
    }

    /// The `boards` holding a clip, in display order, with how many. `limit` caps each count: 1 is enough to know a
    /// board shows. One `fetchCount` per board.
    static func counts(in context: ModelContext, boards: [SmartBoard] = SmartBoard.types,
                       excluding types: [ContentType] = [], includesSecrets: Bool = true,
                       limit: Int? = nil) throws -> [(board: SmartBoard, count: Int)] {
        try boards.compactMap { board in
            var descriptor = FetchDescriptor(predicate: predicate(for: board, excluding: types, includesSecrets: includesSecrets))
            descriptor.fetchLimit = limit
            let count = try context.fetchCount(descriptor)
            return count > 0 ? (board, count) : nil
        }
    }
}
