import Foundation

/// The pure half of the Apple Intelligence rerank: what goes to the model, and what comes back made safe.
enum SuggestionPicks {
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

    /// What the model sees of a clip: its text on one line, at most 120 characters.
    static func preview(_ text: String?) -> String {
        // Only the start of a long clip can reach 120 characters once its whitespace is collapsed.
        let words = (text ?? "").prefix(1_000).split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(120))
    }

    /// `source`'s answer if it comes within `timeout`; nil when it is slower or throws. A late source is cancelled.
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
