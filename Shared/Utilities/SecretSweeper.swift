import Foundation
import SwiftData

/// Deletes secrets once "Delete secrets after" has passed. Runs at launch and every `interval` while the app runs.
enum SecretSweeper {
    static let deleteAfterDefaultsKey = "deleteSecretsAfterMinutes"
    /// Settings' choices, in minutes. 0 is Never.
    static let choices = [1, 5, 15, 60, 0]
    static let defaultMinutes = 5
    static let interval: TimeInterval = 30
    /// Lets the system batch the timer with other wake-ups; a secret lives up to 40 s past its time.
    static let tolerance: TimeInterval = 10

    /// Nil when set to Never, or while "Protect secrets" is off: turning protection off stops the sweep too.
    static var deleteAfter: TimeInterval? {
        guard SecretDetector.isProtecting else { return nil }
        let minutes = SecretDetector.settings.object(forKey: deleteAfterDefaultsKey) as? Int ?? defaultMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    /// The secrets copied at least `after` ago. A copy time ahead of `now` (another clock) has not started yet.
    /// A kept secret, pinned or on a pinboard, never expires.
    static func expired(clips: [(id: UUID, copiedAt: Date, isSensitive: Bool, isKept: Bool)], now: Date, after: TimeInterval?) -> [UUID] {
        guard let after else { return [] }
        return clips.filter { $0.isSensitive && !$0.isKept && now.timeIntervalSince($0.copiedAt) >= after }.map(\.id)
    }

    /// Deletes expired secrets, then saves. A secret on a pinboard is kept, so no entry ever loses its clip. The sync
    /// tracker sends no delete: a secret never uploaded. Returns how many it deleted.
    @MainActor @discardableResult
    static func sweep(in context: ModelContext, now: Date = .now, after: TimeInterval? = deleteAfter) -> Int {
        // No entries read, no sweep: deleting blind could take a secret the user kept on a pinboard.
        // ponytail: every entry in memory; pinboards are small, as in RemoteApplier.
        guard after != nil,
              let secrets = try? context.fetch(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.isSensitive == true })),
              !secrets.isEmpty,
              let entries = try? context.fetch(FetchDescriptor<PinboardEntry>())
        else { return 0 }
        let onBoards = Set(entries.compactMap { $0.clipboardItem?.id })
        let ids = Set(expired(clips: secrets.map { ($0.id, $0.copiedAt, $0.isSensitive, $0.isPinned || onBoards.contains($0.id)) },
                              now: now, after: after))
        guard !ids.isEmpty else { return 0 }
        for clip in secrets where ids.contains(clip.id) { context.delete(clip) }
        try? context.save()
        return ids.count
    }
}
