import Foundation
import SwiftData

/// Orders clips by how likely the user is to paste them next in an app, from the paste history alone.
enum SuggestionRanker {
    struct Candidate: Equatable, Sendable {
        let id: UUID
        let copiedAt: Date
        let isPinned: Bool
    }

    struct Event: Equatable, Sendable {
        let clipID: UUID
        let appBundleID: String
        let at: Date
    }

    private static let day: TimeInterval = 86_400
    private static let week: TimeInterval = 7 * day

    /// The top `limit` candidates by `3·(pastes in app) + 1·(pastes anywhere) + 0.5·recency(copiedAt)`, where each
    /// paste halves weekly and recency halves daily. Ties go to the newer copy. Events of clips that are not
    /// candidates are ignored. A clip never pasted in `app` is only suggested while no candidate was pasted there, so
    /// a new app gets the global habit plus recency, and a fresh install plain recency.
    static func rank(candidates: [Candidate], events: [Event], app: String?, now: Date, limit: Int = 3) -> [UUID] {
        // Dates ahead of `now` (another device's clock) count as now.
        func decay(_ date: Date, halfLife: TimeInterval) -> Double {
            pow(0.5, max(0, now.timeIntervalSince(date)) / halfLife)
        }
        var here: [UUID: Double] = [:], anywhere: [UUID: Double] = [:]
        for event in events {
            let weight = decay(event.at, halfLife: week)
            anywhere[event.clipID, default: 0] += weight
            if event.appBundleID == app { here[event.clipID, default: 0] += weight }
        }
        let anyHere = candidates.contains { here[$0.id] != nil }
        return candidates
            .filter { here[$0.id] != nil || !anyHere }
            .map { ($0, 3 * here[$0.id, default: 0] + anywhere[$0.id, default: 0] + 0.5 * decay($0.copiedAt, halfLife: day)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.copiedAt > $1.0.copiedAt }
            .prefix(limit)
            .map(\.0.id)
    }
}

extension SuggestionRanker {
    /// What suggestions pick from: the last 200 clips plus pinned clips, each once, never a file. Suggestions are
    /// text-like picks and the model must never see a file; pinned file clips still show in the usual row.
    static func candidateClips(in context: ModelContext) -> [ClipboardItem] {
        let fileRaw = ContentType.fileURL.rawValue, filesRaw = ContentType.files.rawValue
        var recent = FetchDescriptor<ClipboardItem>(
            predicate: #Predicate { $0.contentTypeRaw != fileRaw && $0.contentTypeRaw != filesRaw },
            sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        recent.fetchLimit = 200
        var pinned = FetchDescriptor<ClipboardItem>(predicate: #Predicate {
            $0.isPinned == true && $0.contentTypeRaw != fileRaw && $0.contentTypeRaw != filesRaw
        })
        // Only what ranking and the prompt read; the rest (rawData, thumbnails) loads if something else reads it.
        recent.propertiesToFetch = [\.id, \.copiedAt, \.isPinned, \.contentTypeRaw, \.textContent]
        pinned.propertiesToFetch = recent.propertiesToFetch
        var seen = Set<UUID>()
        return (((try? context.fetch(recent)) ?? []) + ((try? context.fetch(pinned)) ?? []))
            .filter { seen.insert($0.id).inserted }
    }
}

/// The History row while suggestions show: up to three suggested clips first, then the usual cards without them.
enum SuggestedRow {
    /// "Show suggestions" in General, on by default.
    static let enabledDefaultsKey = "showSuggestions"

    static func merge<Card: Identifiable>(suggested: [Card], rest: [Card]) -> [Card] {
        let ids = Set(suggested.map(\.id))
        return suggested + rest.filter { !ids.contains($0.id) }
    }
}
