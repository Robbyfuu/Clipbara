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

        // Deletes win over saves; a record inserted and deleted in the same save never reached the server.
        let insertedIDs = Set(context.insertedModelsArray.compactMap(Self.syncID))
        // Deletes check the type only: rawData is an external-storage blob. A delete the server never
        // saw (an oversized clip) comes back as unknownItem, which the engine ignores. A secret and its
        // entries never uploaded, so deleting them (the sweep, or by hand) sends nothing.
        for model in context.deletedModelsArray {
            guard let id = Self.syncID(model), !suppressed.contains(id) else { continue }
            if insertedIDs.contains(id) { seen.insert(id); continue }
            switch model {
            case let clip as ClipboardItem where clip.contentTypeRaw != "fileURL" && !clip.isSensitive:
                add(clip.id, delete: true)
            case let board as Pinboard: add(board.id, delete: true)
            case let entry as PinboardEntry
                where entry.clipboardItem?.contentTypeRaw != "fileURL" && entry.clipboardItem?.isSensitive != true:
                add(entry.id, delete: true)
            default: break
            }
        }
        // Suppression is checked first: isSyncEligible reads rawData.
        for model in context.insertedModelsArray + context.changedModelsArray {
            guard let id = Self.syncID(model), !suppressed.contains(id) else { continue }
            switch model {
            case let clip as ClipboardItem where clip.isSyncEligible: add(clip.id, delete: false)
            case let board as Pinboard: add(board.id, delete: false)
            case let entry as PinboardEntry where entry.clipboardItem?.isSyncEligible == true && entry.pinboard != nil:
                add(entry.id, delete: false)
            default: break
            }
        }
        if !out.isEmpty { onChanges(out) }
    }

    private static func syncID(_ model: any PersistentModel) -> UUID? {
        switch model {
        case let m as ClipboardItem: m.id
        case let m as Pinboard: m.id
        case let m as PinboardEntry: m.id
        default: nil
        }
    }
}
