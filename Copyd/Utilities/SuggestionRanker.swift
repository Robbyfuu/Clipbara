import Foundation

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
