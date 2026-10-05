import Foundation
import SwiftData

/// One clip picked into an app, for suggestions. Mac only and never synced: it lives outside `Shared/`, so the
/// iPhone's schemas never see it, and `LocalChangeTracker` only reports clips, pinboards and their entries.
@Model
final class PasteEvent {
    var clipID: UUID
    var appBundleID: String
    var at: Date

    init(clipID: UUID, appBundleID: String, at: Date = .now) {
        self.clipID = clipID
        self.appBundleID = appBundleID
        self.at = at
    }
}

@MainActor
extension PasteEvent {
    static let kept = 2_000

    /// One event per clip, then only the newest `kept` events remain.
    static func record(_ clipIDs: [UUID], app: String, at date: Date = .now, in context: ModelContext) {
        for id in clipIDs { context.insert(PasteEvent(clipID: id, appBundleID: app, at: date)) }
        try? context.save()
        var older = FetchDescriptor<PasteEvent>(sortBy: [SortDescriptor(\.at, order: .reverse)])
        older.fetchOffset = kept
        guard let stale = try? context.fetch(older), !stale.isEmpty else { return }
        for event in stale { context.delete(event) }
        try? context.save()
    }

    /// Deletes a clip's events with it, whatever deletes it: the panel, Clear History, the history limit or sync.
    /// Watches the main context's saves, as `PasteService.removeFilesOnDelete` does, and deletes right after the
    /// save rather than inside it.
    static func removeWithClips(in context: ModelContext) {
        // Read only inside assumeIsolated: the main context posts willSave synchronously on the main thread.
        nonisolated(unsafe) let context = context
        _ = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) { _ in
            MainActor.assumeIsolated {
                let ids = context.deletedModelsArray.compactMap { ($0 as? ClipboardItem)?.id }
                guard !ids.isEmpty else { return }
                Task { @MainActor in
                    let events = (try? context.fetch(FetchDescriptor<PasteEvent>(predicate: #Predicate { ids.contains($0.clipID) }))) ?? []
                    guard !events.isEmpty else { return }
                    for event in events { context.delete(event) }
                    try? context.save()
                }
            }
        }
    }
}
