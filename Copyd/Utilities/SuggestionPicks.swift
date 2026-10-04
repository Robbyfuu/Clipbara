import Foundation

/// The pure half of the Apple Intelligence rerank: what goes to the model, and what comes back made safe.
enum SuggestionPicks {
    /// The latency budget: at most this many of the habit's top clips go to the model, each as at most
    /// `previewLimit` characters, so an answer usually lands within `SuggestionModel.timeout`.
    static let rerankCandidateLimit = 8
    static let previewLimit = 80

    /// What the model reorders: the habit's top `rerankCandidateLimit`, or nothing when there are 3 or fewer
    /// candidates, which the row already shows in full.
    static func rerankInput<T>(_ habit: [T]) -> [T] {
        habit.count > 3 ? Array(habit.prefix(rerankCandidateLimit)) : []
    }

    /// The model's indices kept in its order: in `0..<count`, each once, at most `limit`.
    static func validate(indices: [Int], count: Int, limit: Int = 3) -> [Int] {
        var seen = Set<Int>()
        return Array(indices.filter { (0..<count).contains($0) && seen.insert($0).inserted }.prefix(limit))
    }

    /// The valid picks first, then the habit order fills the row back to `limit`. Nil when no pick is valid,
    /// so the habit order stays.
    static func reorder<ID: Hashable>(_ indices: [Int], of habit: [ID], limit: Int = 3) -> [ID]? {
        let picks = validate(indices: indices, count: habit.count, limit: limit).map { habit[$0] }
        guard !picks.isEmpty else { return nil }
        let picked = Set(picks)
        return Array((picks + habit.filter { !picked.contains($0) }).prefix(limit))
    }

    /// What the model sees of a clip: its text on one line, at most `previewLimit` characters.
    static func preview(_ text: String?) -> String {
        // Only the start of a long clip can reach `previewLimit` characters once its whitespace is collapsed.
        let words = (text ?? "").prefix(1_000).split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(previewLimit))
    }

    /// `source`'s answer if it comes within `timeout`; nil when it is slower or throws. A late source is cancelled.
    /// Not a hard bound: the group waits for its children, so a source that ignores cancellation delays the return
    /// until it ends. The result is still always nil after the timeout, and the caller is only suspended, so it never
    /// blocks the main actor.
    static func firstWithin<T: Sendable>(timeout: Duration, _ source: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await source() }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
