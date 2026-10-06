import CloudKit

/// Chooses which pending changes go into one upload batch, and in what order.
enum SyncBatchPlanner {
    enum Kind: Int, Comparable {
        case clip, pinboard, entry, appIdentity
        static func < (l: Kind, r: Kind) -> Bool { l.rawValue < r.rawValue }
    }

    /// `kind` is nil for deletes.
    struct Candidate {
        let change: CKSyncEngine.PendingRecordZoneChange
        let kind: Kind?
        let byteCount: Int
    }

    /// Deletes first, then saves ordered clip, pinboard, entry, app identity. Returns a prefix of that order:
    /// the first candidate is always taken, then it stops before exceeding either cap.
    static func select(
        _ candidates: [Candidate], maxRecords: Int = 100, maxBytes: Int = 52_428_800
    ) -> [CKSyncEngine.PendingRecordZoneChange] {
        // Deletes have no kind and sort first; a save with nil kind cannot occur (it would sort as a delete).
        let ordered = candidates.enumerated().sorted {
            let l = $0.element.kind.map { $0.rawValue } ?? -1
            let r = $1.element.kind.map { $0.rawValue } ?? -1
            return l != r ? l < r : $0.offset < $1.offset
        }.map(\.element)

        var picked: [CKSyncEngine.PendingRecordZoneChange] = []
        var bytes = 0
        for c in ordered {
            if !picked.isEmpty, picked.count + 1 > maxRecords || bytes + c.byteCount > maxBytes { break }
            picked.append(c.change)
            bytes += c.byteCount
        }
        return picked
    }
}
