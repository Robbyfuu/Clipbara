import CloudKit
import SwiftData

/// Turns every save on the main context into `CKSyncEngine` pending changes.
/// Relies on `ModelContext.willSave` being posted synchronously on the saving (main) thread.
@MainActor final class LocalChangeTracker {
    private let context: ModelContext
    private let onChanges: @MainActor ([CKSyncEngine.PendingRecordZoneChange]) -> Void
    private var suppressed: Set<UUID> = []
    nonisolated(unsafe) private var token: NSObjectProtocol?  // only touched in init and deinit

    init(context: ModelContext, onChanges: @escaping @MainActor ([CKSyncEngine.PendingRecordZoneChange]) -> Void) {
        self.context = context
        self.onChanges = onChanges
        token = NotificationCenter.default.addObserver(forName: ModelContext.willSave, object: context, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSave() }
        }
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    /// Changes to `ids` made by saves inside `save` are not reported (they came from the server).
    func suppressing(_ ids: Set<UUID>, _ save: () throws -> Void) rethrows {
        let previous = suppressed
        suppressed.formUnion(ids)
        defer { suppressed = previous }
        try save()
    }

    private func willSave() {
        var out: [CKSyncEngine.PendingRecordZoneChange] = []
        var seen: Set<UUID> = []

        func add(_ id: UUID, delete: Bool) {
            guard !suppressed.contains(id), seen.insert(id).inserted else { return }
            let rid = SyncRecordMapper.recordID(for: id)
            out.append(delete ? .deleteRecord(rid) : .saveRecord(rid))
        }

        for model in context.insertedModelsArray + context.changedModelsArray {
            switch model {
            case let clip as ClipboardItem where clip.isSyncEligible: add(clip.id, delete: false)
            case let board as Pinboard: add(board.id, delete: false)
            case let entry as PinboardEntry where entry.clipboardItem?.isSyncEligible == true && entry.pinboard != nil:
                add(entry.id, delete: false)
            default: break
            }
        }
        for model in context.deletedModelsArray {
            switch model {
            case let clip as ClipboardItem where clip.isSyncEligible: add(clip.id, delete: true)
            case let board as Pinboard: add(board.id, delete: true)
            case let entry as PinboardEntry where entry.clipboardItem?.isSyncEligible == true: add(entry.id, delete: true)
            default: break
            }
        }
        if !out.isEmpty { onChanges(out) }
    }
}
