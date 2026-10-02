import Foundation

/// Merges the same content copied on two Macs via Universal Clipboard (spec §10).
enum DuplicateRule {
    static let window: TimeInterval = 60

    struct Merge: Equatable {
        let survivorID: UUID
        let loserID: UUID
        let isPinned: Bool
        let userTitle: String?
        /// The later copy time, so a re-copy merged into an older survivor stays at the top of the history.
        let copiedAt: Date
    }

    /// Returns nil when the clips are not duplicates.
    static func merge(_ a: ClipSnapshot, _ b: ClipSnapshot) -> Merge? {
        guard a.id != b.id, a.contentHash == b.contentHash,
              abs(a.copiedAt.timeIntervalSince(b.copiedAt)) <= window else { return nil }
        let (survivor, loser) = a.id.uuidString < b.id.uuidString ? (a, b) : (b, a)
        return Merge(
            survivorID: survivor.id, loserID: loser.id,
            isPinned: a.isPinned || b.isPinned,
            userTitle: survivor.userTitle ?? loser.userTitle,
            copiedAt: max(a.copiedAt, b.copiedAt))
    }
}
