#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CloudKit
import OSLog
import SwiftData

/// Owns the `CKSyncEngine`: builds upload batches from SwiftData, applies fetched changes,
/// handles send errors (spec section 11) and exposes a status for Settings.
@MainActor @Observable final class CloudSyncEngine: CKSyncEngineDelegate {
    enum Status: Equatable { case off, syncing, upToDate(Date), accountUnavailable, quotaExceeded, accountChanged, error(String) }

    static let enabledDefaultsKey = "iCloudSyncEnabled"
    static let containerID = "iCloud.com.robbyfuu.copyd"

    private(set) var status: Status = .off {
        didSet {
            #if os(iOS)
            if case .upToDate(let date) = status { SharedDefaults.store?.set(date, forKey: SharedDefaults.lastSyncAtKey) }
            #endif
        }
    }

    private let container: ModelContainer
    private let onRemoteChanges: @MainActor () -> Void
    private let stateURL: URL?
    private let assetDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CopydSyncAssets", isDirectory: true)
    private var engine: CKSyncEngine?
    private var tracker: LocalChangeTracker?
    private var accountCheck: Task<Void, Never>?
    private var lastFetch = Date.distantPast
    /// Entries whose clip or pinboard had not arrived yet, with their system fields; retried at didFetchChanges.
    private var orphans: [EntrySnapshot] = []
    private var orphanFields: [UUID: Data] = [:]
    /// Re-queued changes held back until the next willSendChanges: the engine keeps asking for
    /// batches until it gets nil, so resending them in the same send would loop.
    private var deferred: Set<UUID> = []
    #if os(iOS)
    /// Called once a fetch finishes, with the clips it brought that this iPhone never had (`Outcome.arrivals`).
    /// Local captures and Universal Clipboard never pass through here. The first fetch of a fresh state (install,
    /// sign-in, a wiped mirror) downloads the whole history and is not reported.
    @ObservationIgnored var onRemoteInserts: (@MainActor ([UUID]) -> Void)?
    @ObservationIgnored private var arrivals: Set<UUID> = []
    @ObservationIgnored private var reportsArrivals = false
    #endif

    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "Sync")
    private static let batchRecords = 100
    private static let batchBytes = 52_428_800
    /// CKSyncEngine retries these on its own.
    private static let retryable: Set<CKError.Code> = [
        .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
        .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled,
    ]

    private var modelContext: ModelContext { container.mainContext }

    init(container: ModelContainer, onRemoteChanges: @escaping @MainActor () -> Void) {
        self.container = container
        self.onRemoteChanges = onRemoteChanges
        if let config = container.configurations.first, !config.isStoredInMemoryOnly {
            stateURL = config.url.deletingLastPathComponent().appendingPathComponent("SyncState.data")
        } else {
            stateURL = nil
            Self.log.notice("In-memory store: sync state is kept in memory only")
        }
    }

    // MARK: - Public

    /// No-op while running. The engine stays dormant until an iCloud account is present,
    /// so local changes are captured from the start; the account check only drives `status`.
    func start() {
        guard engine == nil else { return }
        status = .syncing  // until the first engine event or the account check says otherwise
        startEngine()
        accountCheck = Task { [weak self] in
            let account = try? await CKContainer(identifier: Self.containerID).accountStatus()
            guard let self, !Task.isCancelled, account != .available else { return }
            Self.log.notice("iCloud account not available: \(String(describing: account), privacy: .public)")
            status = .accountUnavailable
        }
    }

    /// No-op when no engine runs: when the engine turns sync off itself, the Settings toggle's
    /// onChange calls this again, and that must not re-clear state or overwrite `.accountChanged`.
    func stop(clearState: Bool) {
        guard engine != nil else { return }
        accountCheck?.cancel()
        accountCheck = nil
        if let engine { Task { await engine.cancelOperations() } }
        if clearState {
            if let stateURL, FileManager.default.fileExists(atPath: stateURL.path) {
                do { try FileManager.default.removeItem(at: stateURL) } catch {
                    Self.log.error("Could not delete sync state: \(error.syncLogDescription, privacy: .public)")
                }
            }
            clearAllSystemFields()
            orphans = []
            orphanFields = [:]
        }
        engine = nil
        tracker = nil
        status = .off
    }

    /// Forces a fetch, at most once every 30 seconds.
    func fetchIfStale() {
        guard let engine, Date().timeIntervalSince(lastFetch) >= 30 else { return }
        lastFetch = Date()
        Task {
            do { try await engine.fetchChanges() } catch {
                Self.log.error("Forced fetch failed: \(error.syncLogDescription, privacy: .public)")
            }
        }
    }

    // MARK: - CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // An engine dropped by stop() can still deliver events; they must not touch state or models.
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let e):
            writeState(e.stateSerialization)
        case .accountChange(let e):
            handleAccountChange(e.changeType, engine: syncEngine)
        case .fetchedDatabaseChanges(let e):
            handleZoneDeletions(e.deletions, engine: syncEngine)
        case .fetchedRecordZoneChanges(let e):
            applyFetched(e, engine: syncEngine)
        case .sentRecordZoneChanges(let e):
            handleSent(e, engine: syncEngine)
        case .sentDatabaseChanges(let e):
            for f in e.failedZoneSaves where !Self.retryable.contains(f.error.code) {
                Self.log.error("Zone save failed: \(f.error.syncLogDescription, privacy: .public)")
                status = .error(f.error.localizedDescription)
            }
        case .willFetchChanges:
            status = .syncing
        case .willSendChanges:
            deferred = []
            status = .syncing
        case .didFetchChanges:
            retryOrphans(engine: syncEngine)
            #if os(iOS)
            if reportsArrivals, !arrivals.isEmpty { onRemoteInserts?(Array(arrivals)) }
            arrivals = []
            reportsArrivals = true
            #endif
            lastFetch = Date()
            status = .upToDate(Date())
        case .didSendChanges:
            switch status {
            case .error, .quotaExceeded, .accountUnavailable, .accountChanged: break
            default: status = .upToDate(Date())
            }
        case .didFetchRecordZoneChanges(let e):
            if let error = e.error { Self.log.error("Zone fetch failed: \(error.syncLogDescription, privacy: .public)") }
        case .willFetchRecordZoneChanges:
            break
        @unknown default:
            Self.log.notice("Unhandled sync event")
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        let clips: [UUID: ClipboardItem], boards: [UUID: Pinboard], entries: [UUID: PinboardEntry]
        do {
            clips = Self.byID(try modelContext.fetch(FetchDescriptor<ClipboardItem>()), \.id)
            boards = Self.byID(try modelContext.fetch(FetchDescriptor<Pinboard>()), \.id)
            entries = Self.byID(try modelContext.fetch(FetchDescriptor<PinboardEntry>()), \.id)
        } catch {
            Self.log.error("Could not read models for upload: \(error.syncLogDescription, privacy: .public)")
            return nil
        }

        var candidates: [SyncBatchPlanner.Candidate] = []
        var dead: [CKSyncEngine.PendingRecordZoneChange] = []
        var sizedClips = 0, sizedBytes = 0
        // An entry sent without its clip is rejected with referenceViolation, so entries wait while a clip is held back.
        var clipsHeldBack = false
        for change in syncEngine.state.pendingRecordZoneChanges where context.options.scope.contains(change) {
            if case .deleteRecord(let rid) = change {
                if let id = UUID(uuidString: rid.recordName), deferred.contains(id) { continue }
                candidates.append(.init(change: change, kind: nil, byteCount: 0))
                continue
            }
            guard case .saveRecord(let rid) = change else { continue }
            guard let id = UUID(uuidString: rid.recordName) else { dead.append(change); continue }
            if deferred.contains(id) {
                if clips[id] != nil || boards[id] != nil { clipsHeldBack = true }
                continue
            }
            if let clip = clips[id] {
                // fileURL first: rawData is external storage and reading it loads the blob.
                if clip.contentTypeRaw == "fileURL" { dead.append(change); continue }
                // Size only the clips that can fit in this batch; the planner stops at either cap.
                guard sizedClips < Self.batchRecords, sizedBytes < Self.batchBytes else { clipsHeldBack = true; continue }
                let bytes = clip.rawData.count
                // Per type: a file bundle may be bigger than any other clip.
                guard SyncRecordMapper.isEligible(contentType: clip.contentTypeRaw, byteCount: bytes) else { dead.append(change); continue }
                let byteCount = bytes + (clip.textContent?.utf8.count ?? 0)
                sizedClips += 1
                sizedBytes += byteCount
                candidates.append(.init(change: change, kind: .clip, byteCount: byteCount))
            } else if boards[id] != nil {
                candidates.append(.init(change: change, kind: .pinboard, byteCount: 0))
            } else if let clipID = entries[id]?.snapshot?.clipID, let clip = clips[clipID],
                      clip.contentTypeRaw != "fileURL", clip.isSyncEligible {
                // ponytail: sizes every pending entry's clip; entries are few, cap them like clips if that changes.
                candidates.append(.init(change: change, kind: .entry, byteCount: 0))
            } else {
                // Deleted since it was queued, an entry that lost its clip or pinboard, or an entry of an ineligible clip.
                dead.append(change)
            }
        }
        if !dead.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: dead) }
        // Held-back entries stay pending for the next batch.
        if clipsHeldBack { candidates.removeAll { $0.kind == .entry } }

        do {
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        } catch { Self.log.error("Could not create asset directory: \(error.syncLogDescription, privacy: .public)") }

        var toSave: [CKRecord] = []
        var toDelete: [CKRecord.ID] = []
        for change in SyncBatchPlanner.select(candidates, maxRecords: Self.batchRecords, maxBytes: Self.batchBytes) {
            switch change {
            case .deleteRecord(let rid):
                toDelete.append(rid)
            case .saveRecord(let rid):
                guard let id = UUID(uuidString: rid.recordName) else { continue }
                do {
                    if let m = clips[id] {
                        let r = Self.record(SyncRecordMapper.clipType, rid, m.syncSystemFields)
                        try SyncRecordMapper.populate(r, from: m.snapshot, assetDirectory: assetDirectory)
                        toSave.append(r)
                    } else if let m = boards[id] {
                        let r = Self.record(SyncRecordMapper.pinboardType, rid, m.syncSystemFields)
                        SyncRecordMapper.populate(r, from: m.snapshot)
                        toSave.append(r)
                    } else if let m = entries[id], let s = m.snapshot {
                        let r = Self.record(SyncRecordMapper.entryType, rid, m.syncSystemFields)
                        SyncRecordMapper.populate(r, from: s)
                        toSave.append(r)
                    }
                } catch {
                    Self.log.error("Record \(id, privacy: .public) not built: \(error.syncLogDescription, privacy: .public)")
                }
            @unknown default:
                continue
            }
        }
        if toSave.isEmpty && toDelete.isEmpty { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: toSave, recordIDsToDelete: toDelete, atomicByZone: false)
    }

    // MARK: - Events

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType, engine: CKSyncEngine) {
        switch change {
        case .signIn:
            // The engine clears its pending changes when the account changes, so queue everything again.
            // start() queued it too when there was no saved state; the state deduplicates.
            queueEverything(on: engine)
            status = .syncing
        case .signOut, .switchAccounts:
            #if os(iOS)
            // The phone is a mirror with no sync toggle: drop the old account's history (macOS keeps it)
            // and start over, which cannot mix accounts because nothing local is left.
            save(suppressing: RemoteApplier.deleteAll(in: modelContext))
            restartEmpty()
            #else
            // Never mix two accounts' data: sync stays off until the user enables it again.
            stop(clearState: true)
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            status = .accountChanged
            #endif
        @unknown default:
            Self.log.notice("Unhandled account change: \(String(describing: change), privacy: .public)")
        }
    }

    private func handleZoneDeletions(_ deletions: [CKDatabase.DatabaseChange.Deletion], engine: CKSyncEngine) {
        // Compare names only: server zone IDs may carry the real owner name instead of the default one.
        for d in deletions where d.zoneID.zoneName == SyncRecordMapper.zoneID.zoneName {
            switch d.reason {
            case .encryptedDataReset:
                Self.log.notice("Zone reset (encryptedDataReset): uploading everything again")
                clearAllSystemFields()
                queueEverything(on: engine)
            case .deleted, .purged:
                #if os(iOS)
                Self.log.notice("Zone removed from iCloud: clearing the mirror and starting over")
                // Wipe before restarting, or the restart's queueEverything re-uploads what the user deleted.
                save(suppressing: RemoteApplier.deleteAll(in: modelContext))
                restartEmpty()
                #else
                Self.log.notice("Zone removed from iCloud: turning sync off")
                stop(clearState: true)
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
                #endif
                return
            @unknown default:
                Self.log.notice("Unhandled zone deletion reason: \(String(describing: d.reason), privacy: .public)")
            }
        }
    }

    #if os(iOS)
    /// iOS has no sync toggle, so turning sync off would be permanent. Call only once the local mirror is empty.
    /// The stopped engine's late events and batch requests fail the `syncEngine === engine` checks.
    private func restartEmpty() {
        stop(clearState: true)  // drops the tracker, so no observer forwards saves to the next engine
        SharedDefaults.store?.removeObject(forKey: SharedDefaults.lastSyncAtKey)
        Task { @MainActor [weak self] in self?.start() }
    }
    #endif

    private func applyFetched(_ e: CKSyncEngine.Event.FetchedRecordZoneChanges, engine: CKSyncEngine) {
        // A local deletion still waiting to upload wins: never re-insert what the user deleted.
        let pendingDeletes = Set(engine.state.pendingRecordZoneChanges.compactMap { change -> String? in
            if case .deleteRecord(let rid) = change { rid.recordName } else { nil }
        })
        var clips: [ClipSnapshot] = [], boards: [PinboardSnapshot] = [], entries: [EntrySnapshot] = []
        var fields: [UUID: Data] = [:]
        for m in e.modifications where !pendingDeletes.contains(m.record.recordID.recordName) {
            let r = m.record
            do {
                switch r.recordType {
                case SyncRecordMapper.clipType: clips.append(try SyncRecordMapper.clip(from: r))
                case SyncRecordMapper.pinboardType: boards.append(try SyncRecordMapper.pinboard(from: r))
                case SyncRecordMapper.entryType: entries.append(try SyncRecordMapper.entry(from: r))
                default:
                    Self.log.notice("Skipped record of unknown type \(r.recordType, privacy: .public)")
                    continue
                }
                if let id = UUID(uuidString: r.recordID.recordName) { fields[id] = Self.archive(r) }
            } catch {
                Self.log.error("Skipped undecodable record \(r.recordID.recordName, privacy: .public): \(error.syncLogDescription, privacy: .public)")
            }
        }
        let deletions = e.deletions.compactMap { UUID(uuidString: $0.recordID.recordName) }
        // A remote deletion beats a local edit.
        engine.state.remove(pendingRecordZoneChanges: deletions.map { .saveRecord(SyncRecordMapper.recordID(for: $0)) })
        // A newer version or a deletion replaces a held orphan.
        let superseded = Set(entries.map(\.id)).union(deletions)
        orphans.removeAll { superseded.contains($0.id) }
        orphanFields = orphanFields.filter { !superseded.contains($0.key) }

        let out = applyRemote(clips: clips, pinboards: boards, entries: entries, deletions: deletions,
                              fields: fields, engine: engine)
        #if os(iOS)
        arrivals.formUnion(out.arrivals)
        #endif
        for o in out.orphans {
            orphans.append(o)
            orphanFields[o.id] = fields[o.id]
        }
    }

    private func retryOrphans(engine: CKSyncEngine) {
        guard !orphans.isEmpty else { return }
        let held = orphans, fields = orphanFields
        orphans = []
        orphanFields = [:]
        let out = applyRemote(entries: held, fields: fields, engine: engine)
        for o in out.orphans {
            Self.log.notice("Dropped entry \(o.id, privacy: .public): its clip or pinboard never arrived")
        }
    }

    private func handleSent(_ e: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        var fields: [UUID: Data?] = [:]  // a nil value clears the stored system fields
        var requeue: [CKSyncEngine.PendingRecordZoneChange] = []
        var remoteDeleted: [UUID] = []
        var zoneMissing = false
        func resendLater(_ change: CKSyncEngine.PendingRecordZoneChange, _ id: UUID) {
            deferred.insert(id)
            requeue.append(change)
        }

        for r in e.savedRecords {
            removeAssets(of: r)
            if let id = UUID(uuidString: r.recordID.recordName) { fields[id] = Self.archive(r) }
        }
        for f in e.failedRecordSaves {
            removeAssets(of: f.record)
            guard let id = UUID(uuidString: f.record.recordID.recordName) else { continue }
            let save = CKSyncEngine.PendingRecordZoneChange.saveRecord(SyncRecordMapper.recordID(for: id))
            switch f.error.code {
            case .serverRecordChanged:
                // Local pending change wins: keep local values, resend on the server's system fields.
                if let server = f.error.serverRecord {
                    fields[id] = Self.archive(server)
                    requeue.append(save)
                } else {
                    resendLater(save, id)
                }
            case .zoneNotFound:
                zoneMissing = true
                fields.updateValue(nil, forKey: id)
                resendLater(save, id)
            case .referenceViolation:
                // A target that failed in this event or is still queued has not reached the server yet: keep the entry.
                let targets = ["clip", "pinboard"].compactMap { (f.record[$0] as? CKRecord.Reference)?.recordID }
                if targets.contains(where: { t in
                    e.failedRecordSaves.contains { $0.record.recordID == t }
                        || engine.state.pendingRecordZoneChanges.contains(.saveRecord(t))
                }) {
                    resendLater(save, id)
                } else {
                    remoteDeleted.append(id)  // the clip or pinboard it references was deleted elsewhere
                }
            case .unknownItem:
                remoteDeleted.append(id)  // another device deleted it
            case .quotaExceeded:
                status = .quotaExceeded
                resendLater(save, id)
            case .limitExceeded:
                Self.log.error("Batch too large: \(id, privacy: .public) resent in the next send")
                resendLater(save, id)
            case let code where Self.retryable.contains(code):
                break
            default:
                Self.log.error("Save of \(id, privacy: .public) failed: \(f.error.syncLogDescription, privacy: .public)")
                status = .error(f.error.localizedDescription)
            }
        }
        for (rid, error) in e.failedRecordDeletes {
            switch error.code {
            case .unknownItem, .zoneNotFound:
                break  // already gone
            case .limitExceeded:
                guard let id = UUID(uuidString: rid.recordName) else { continue }
                Self.log.error("Batch too large: delete of \(id, privacy: .public) resent in the next send")
                resendLater(.deleteRecord(SyncRecordMapper.recordID(for: id)), id)
            case let code where Self.retryable.contains(code):
                break
            default:
                Self.log.error("Delete of \(rid.recordName, privacy: .public) failed: \(error.syncLogDescription, privacy: .public)")
                status = .error(error.localizedDescription)
            }
        }

        storeSystemFields(fields)
        if !remoteDeleted.isEmpty {
            engine.state.remove(pendingRecordZoneChanges: remoteDeleted.map { .saveRecord(SyncRecordMapper.recordID(for: $0)) })
            applyRemote(deletions: remoteDeleted, fields: [:], engine: engine)
        }
        if zoneMissing {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncRecordMapper.zoneID))])
        }
        engine.state.add(pendingRecordZoneChanges: requeue)
    }

    // MARK: - SwiftData writes (always inside tracker.suppressing, no await before the save)

    /// Applies remote changes, saves them without echo, and queues the uploads the merge produced.
    @discardableResult
    private func applyRemote(clips: [ClipSnapshot] = [], pinboards: [PinboardSnapshot] = [], entries: [EntrySnapshot] = [],
                             deletions: [UUID] = [], fields: [UUID: Data], engine: CKSyncEngine) -> RemoteApplier.Outcome {
        // One snapshot of the pending list: it cannot change during apply, and reading it per record is O(n).
        let pending = Set(engine.state.pendingRecordZoneChanges)
        let applier = RemoteApplier(context: modelContext) { pending.contains(.saveRecord(SyncRecordMapper.recordID(for: $0))) }
        let out = applier.apply(clips: clips, pinboards: pinboards, entries: entries, deletions: deletions, systemFields: fields)
        save(suppressing: out.touched)
        engine.state.add(pendingRecordZoneChanges: out.saves.map { .saveRecord(SyncRecordMapper.recordID(for: $0)) }
            + out.deletes.map { .deleteRecord(SyncRecordMapper.recordID(for: $0)) })
        if !out.touched.isEmpty { onRemoteChanges() }
        return out
    }

    private func storeSystemFields(_ fields: [UUID: Data?]) {
        guard !fields.isEmpty else { return }
        for (id, data) in fields {
            if let m = modelContext.syncClip(id: id) {
                m.syncSystemFields = data
            } else if let m = modelContext.syncPinboard(id: id) {
                m.syncSystemFields = data
            } else if let m = modelContext.syncEntry(id: id) {
                m.syncSystemFields = data
            }
        }
        save(suppressing: Set(fields.keys))
    }

    private func clearAllSystemFields() {
        var ids: Set<UUID> = []
        do {
            ids.formUnion(try modelContext.fetch(FetchDescriptor<ClipboardItem>()).map(\.id))
            ids.formUnion(try modelContext.fetch(FetchDescriptor<Pinboard>()).map(\.id))
            ids.formUnion(try modelContext.fetch(FetchDescriptor<PinboardEntry>()).map(\.id))
        } catch { Self.log.error("Could not list models to clear: \(error.syncLogDescription, privacy: .public)") }
        RemoteApplier.clearSystemFields(in: modelContext)
        save(suppressing: ids)
    }

    private func save(suppressing ids: Set<UUID>) {
        do {
            if let tracker {
                try tracker.suppressing(ids) { try modelContext.save() }
            } else {
                try modelContext.save()  // no tracker, so nothing can echo
            }
        } catch {
            Self.log.error("Sync save failed: \(error.syncLogDescription, privacy: .public)")
        }
    }

    // MARK: - Engine setup

    private func startEngine() {
        try? FileManager.default.removeItem(at: assetDirectory)  // leftovers of sends that never got a result
        let saved = loadState()
        #if os(iOS)
        reportsArrivals = saved != nil
        arrivals = []
        #endif
        let database = CKContainer(identifier: Self.containerID).privateCloudDatabase
        let engine = CKSyncEngine(CKSyncEngine.Configuration(database: database, stateSerialization: saved, delegate: self))
        self.engine = engine
        tracker = LocalChangeTracker(context: modelContext) { [weak self] changes in
            self?.engine?.state.add(pendingRecordZoneChanges: changes)
        }
        #if os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #else
        UIApplication.shared.registerForRemoteNotifications()
        #endif
        if saved == nil {
            queueEverything(on: engine)
        } else {
            // A save that failed with an unexpected error is dropped from pending for good; the missing system fields give it away.
            do {
                let ids = try RemoteApplier.uploadableIDs(in: modelContext, onlyUnconfirmed: true)
                if !ids.isEmpty {
                    engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(SyncRecordMapper.recordID(for: $0)) })
                    Self.log.notice("Re-queued \(ids.count, privacy: .public) unconfirmed records")
                }
            } catch {
                Self.log.error("Could not list unconfirmed records: \(error.syncLogDescription, privacy: .public)")
            }
        }
    }

    /// First enable, sign-in and encryptedDataReset: the zone, every eligible clip, every pinboard, every entry of an eligible clip.
    private func queueEverything(on engine: CKSyncEngine) {
        var ids: [UUID] = []
        do {
            // Oversized clips (and their entries) are dropped when the batch is built.
            ids = try RemoteApplier.uploadableIDs(in: modelContext, onlyUnconfirmed: false)
        } catch {
            Self.log.error("Could not list records to upload: \(error.syncLogDescription, privacy: .public)")
        }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncRecordMapper.zoneID))])
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(SyncRecordMapper.recordID(for: $0)) })
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return nil }
        do {
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            Self.log.error("Discarding unreadable sync state: \(error.syncLogDescription, privacy: .public)")
            return nil
        }
    }

    private func writeState(_ state: CKSyncEngine.State.Serialization) {
        guard let stateURL else { return }
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Self.log.error("Could not write sync state: \(error.syncLogDescription, privacy: .public)")
        }
    }

    /// Both sealed files of a clip record (`rawData` and large `textContent`), once its send result arrived.
    private func removeAssets(of record: CKRecord) {
        guard let id = UUID(uuidString: record.recordID.recordName) else { return }
        try? FileManager.default.removeItem(at: SyncRecordMapper.assetURL(for: id, in: assetDirectory))
        try? FileManager.default.removeItem(at: SyncRecordMapper.textAssetURL(for: id, in: assetDirectory))
    }

    // MARK: - Helpers

    private static func byID<M>(_ models: [M], _ id: (M) -> UUID) -> [UUID: M] {
        Dictionary(models.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func archive(_ record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    /// A record carrying the cached system fields (avoids false conflicts), or a new one.
    private static func record(_ type: CKRecord.RecordType, _ id: CKRecord.ID, _ systemFields: Data?) -> CKRecord {
        if let systemFields, let coder = try? NSKeyedUnarchiver(forReadingFrom: systemFields) {
            coder.requiresSecureCoding = true
            let cached = CKRecord(coder: coder)
            coder.finishDecoding()
            // Type only: a cached recordID can carry the real owner name instead of the default one.
            if let cached, cached.recordType == type { return cached }
        }
        return CKRecord(recordType: type, recordID: id)
    }
}
