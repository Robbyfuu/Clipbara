import Foundation
import SwiftData

/// Deletes secrets once "Delete secrets after" has passed. Runs at launch and every `interval` while the app runs.
enum SecretSweeper {
    static let deleteAfterDefaultsKey = "deleteSecretsAfterMinutes"
    /// Settings' choices, in minutes. 0 is Never.
    static let choices = [1, 5, 15, 60, 0]
    static let defaultMinutes = 5
    static let interval: TimeInterval = 30

    /// Nil when set to Never.
    static var deleteAfter: TimeInterval? {
        let minutes = SecretDetector.settings.object(forKey: deleteAfterDefaultsKey) as? Int ?? defaultMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    /// The secrets copied at least `after` ago. A copy time ahead of `now` (another clock) has not started yet.
    static func expired(clips: [(id: UUID, copiedAt: Date, isSensitive: Bool)], now: Date, after: TimeInterval?) -> [UUID] {
        guard let after else { return [] }
        return clips.filter { $0.isSensitive && now.timeIntervalSince($0.copiedAt) >= after }.map(\.id)
    }

    /// Deletes expired secrets and their pinboard entries, then saves. The sync tracker sends no delete: a secret
    /// never uploaded. Returns how many it deleted.
    @MainActor @discardableResult
    static func sweep(in context: ModelContext, now: Date = .now, after: TimeInterval? = deleteAfter) -> Int {
        guard after != nil,
              let secrets = try? context.fetch(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.isSensitive == true }))
        else { return 0 }
        let ids = Set(expired(clips: secrets.map { ($0.id, $0.copiedAt, $0.isSensitive) }, now: now, after: after))
        guard !ids.isEmpty else { return 0 }
        // ponytail: every entry in memory; pinboards are small, as in RemoteApplier.
        for entry in (try? context.fetch(FetchDescriptor<PinboardEntry>())) ?? [] {
            if let id = entry.clipboardItem?.id, ids.contains(id) { context.delete(entry) }
        }
        for clip in secrets where ids.contains(clip.id) { context.delete(clip) }
        try? context.save()
        return ids.count
    }
}
