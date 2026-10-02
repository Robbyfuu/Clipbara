import AppKit
import CloudKit
import OSLog
import SwiftData

/// Owns the `CKSyncEngine`: builds upload batches from SwiftData, applies fetched changes,
/// handles send errors (spec section 11) and exposes a status for Settings.
@MainActor @Observable final class CloudSyncEngine: CKSyncEngineDelegate {
    enum Status: Equatable { case off, syncing, upToDate(Date), accountUnavailable, quotaExceeded, accountChanged, error(String) }

    static let enabledDefaultsKey = "iCloudSyncEnabled"
    static let containerID = "iCloud.com.robbyfuu.copyd"

    private(set) var status: Status = .off

    private let container: ModelContainer
    private let onRemoteChanges: @MainActor () -> Void
    private let stateURL: URL?
    private let assetDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CopydSyncAssets", isDirectory: true)
    private var engine: CKSyncEngine?
    private var tracker: LocalChangeTracker?
    private var startTask: Task<Void, Never>?
    private var lastFetch = Date.distantPast
    /// Entries whose clip or pinboard had not arrived yet, with their system fields; retried at didFetchChanges.
    private var orphans: [EntrySnapshot] = []
    private var orphanFields: [UUID: Data] = [:]
    /// Saves that hit quotaExceeded in the current send; skipped until the next willSendChanges so they are not resent in a loop.
    private var quotaDeferred: Set<UUID> = []

    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "Sync")
    private static let batchRecords = 100
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

    /// No-op while running or starting. Creates no engine unless the iCloud account is available.
    func start() {
        guard engine == nil, startTask == nil else { return }
        startTask = Task { [weak self] in
            let account = try? await CKContainer(identifier: Self.containerID).accountStatus()
            guard let self, !Task.isCancelled else { return }
            startTask = nil
            guard account == .available else {
                Self.log.notice("iCloud account not available: \(String(describing: account))")
                status = .accountUnavailable
                return
            }
            startEngine()
        }
    }

    func stop(clearState: Bool) {
        startTask?.cancel()
        startTask = nil
        if let engine { Task { await engine.cancelOperations() } }
        if clearState {
            if let stateURL, FileManager.default.fileExists(atPath: stateURL.path) {
                do { try FileManager.default.removeItem(at: stateURL) } catch {
                    Self.log.error("Could not delete sync state: \(error)")
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
            do { try await engine.fetchChanges() } catch { Self.log.error("Forced fetch failed: \(error)") }
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
            handleAccountChange(e.changeType)
        case .fetchedDatabaseChanges(let e):
            handleZoneDeletions(e.deletions, engine: syncEngine)
        case .fetchedRecordZoneChanges(let e):
            applyFetched(e, engine: syncEngine)
        case .sentRecordZoneChanges(let e):
            handleSent(e, engine: syncEngine)
        case .sentDatabaseChanges(let e):
            for f in e.failedZoneSaves where !Self.retryable.contains(f.error.code) {
                Self.log.error("Zone save failed: \(f.error)")
                status = .error(f.error.localizedDescription)
            }
        case .willFetchChanges:
            status = .syncing
        case .willSendChanges:
            quotaDeferred = []
            status = .syncing
        case .didFetchChanges:
            retryOrphans(engine: syncEngine)
            lastFetch = Date()
            status = .upToDate(Date())
        case .didSendChanges:
            switch status {
            case .error, .quotaExceeded, .accountUnavailable, .accountChanged: break
            default: status = .upToDate(Date())
            }
        case .didFetchRecordZoneChanges(let e):
            if let error = e.error { Self.log.error("Zone fetch failed: \(error)") }
        case .willFetchRecordZoneChanges:
            break
        @unknown default:
            Self.log.notice("Unhandled sync event: \(event)")
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
            Self.log.error("Could not read models for upload: \(error)")
            return nil
        }

        var candidates: [SyncBatchPlanner.Candidate] = []
        var dead: [CKSyncEngine.PendingRecordZoneChange] = []
        var sizedClips = 0
        for change in syncEngine.state.pendingRecordZoneChanges where context.options.scope.contains(change) {
            guard case .saveRecord(let rid) = change else {
                candidates.append(.init(change: change, kind: nil, byteCount: 0))
                continue
            }
            guard let id = UUID(uuidString: rid.recordName) else { dead.append(change); continue }
            if quotaDeferred.contains(id) { continue }
            if let clip = clips[id] {
                if clip.contentTypeRaw == "fileURL" { dead.append(change); continue }
                // rawData is external storage: size only the clips that can fit in this batch.
                // The planner never takes more than batchRecords clips, so the result is the same.
                guard sizedClips < Self.batchRecords else { continue }
                let bytes = clip.rawData.count
                guard bytes <= SyncRecordMapper.maxClipBytes else { dead.append(change); continue }
                sizedClips += 1
                candidates.append(.init(change: change, kind: .clip, byteCount: bytes))
            } else if boards[id] != nil {
                candidates.append(.init(change: change, kind: .pinboard, byteCount: 0))
            } else if entries[id]?.snapshot != nil {
                candidates.append(.init(change: change, kind: .entry, byteCount: 0))
            } else {
                dead.append(change)  // deleted since it was queued, or an entry that lost its clip or pinboard
            }
        }
        if !dead.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: dead) }

        do {
            try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        } catch { Self.log.error("Could not create asset directory: \(error)") }

        var toSave: [CKRecord] = []
        var toDelete: [CKRecord.ID] = []
        for change in SyncBatchPlanner.select(candidates, maxRecords: Self.batchRecords) {
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
                    Self.log.error("Record \(id) not built: \(error)")
                }
            @unknown default:
                continue
            }
        }
        if toSave.isEmpty && toDelete.isEmpty { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: toSave, recordIDsToDelete: toDelete, atomicByZone: false)
    }

    // MARK: - Events

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        switch change {
        case .signIn:
            // start() already queued everything when there was no saved state.
            status = .syncing
        case .signOut, .switchAccounts:
            // Never mix two accounts' data: sync stays off until the user enables it again.
            stop(clearState: true)
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            status = .accountChanged
        @unknown default:
            Self.log.notice("Unhandled account change: \(String(describing: change))")
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
                Self.log.notice("Zone removed from iCloud: turning sync off")
                stop(clearState: true)
                UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
                return
            @unknown default:
                Self.log.notice("Unhandled zone deletion reason: \(String(describing: d.reason))")
            }
        }
    }

    private func applyFetched(_ e: CKSyncEngine.Event.FetchedRecordZoneChanges, engine: CKSyncEngine) {
        var clips: [ClipSnapshot] = [], boards: [PinboardSnapshot] = [], entries: [EntrySnapshot] = []
        var fields: [UUID: Data] = [:]
        for m in e.modifications {
            let r = m.record
            do {
                switch r.recordType {
                case SyncRecordMapper.clipType: clips.append(try SyncRecordMapper.clip(from: r))
                case SyncRecordMapper.pinboardType: boards.append(try SyncRecordMapper.pinboard(from: r))
                case SyncRecordMapper.entryType: entries.append(try SyncRecordMapper.entry(from: r))
                default:
                    Self.log.notice("Skipped record of unknown type \(r.recordType)")
                    continue
                }
                if let id = UUID(uuidString: r.recordID.recordName) { fields[id] = Self.archive(r) }
            } catch {
                Self.log.error("Skipped undecodable record \(r.recordID.recordName): \(error)")
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
        for o in out.orphans { Self.log.notice("Dropped entry \(o.id): its clip or pinboard never arrived") }
    }

    private func handleSent(_ e: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine) {
        var fields: [UUID: Data?] = [:]  // a nil value clears the stored system fields
        var requeue: [UUID] = []
        var remoteDeleted: [UUID] = []
        for r in e.savedRecords {
            removeAsset(of: r)
            if let id = UUID(uuidString: r.recordID.recordName) { fields[id] = Self.archive(r) }
        }
        for f in e.failedRecordSaves {
            removeAsset(of: f.record)
            guard let id = UUID(uuidString: f.record.recordID.recordName) else { continue }
            switch f.error.code {
            case .serverRecordChanged:
                // Local pending change wins: keep local values, resend on the server's system fields.
                if let server = f.error.serverRecord { fields[id] = Self.archive(server) }
                requeue.append(id)
            case .zoneNotFound:
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncRecordMapper.zoneID))])
                fields.updateValue(nil, forKey: id)
                requeue.append(id)
            case .unknownItem:
                remoteDeleted.append(id)  // another device deleted it
            case .quotaExceeded:
                status = .quotaExceeded
                quotaDeferred.insert(id)
                requeue.append(id)
            case let code where Self.retryable.contains(code):
                break
            default:
                Self.log.error("Save of \(id) failed: \(f.error)")
                status = .error(f.error.localizedDescription)
            }
        }
        for (rid, error) in e.failedRecordDeletes
        where error.code != .unknownItem && !Self.retryable.contains(error.code) {
            Self.log.error("Delete of \(rid.recordName) failed: \(error)")
            status = .error(error.localizedDescription)
        }

        storeSystemFields(fields)
        if !remoteDeleted.isEmpty {
            engine.state.remove(pendingRecordZoneChanges: remoteDeleted.map { .saveRecord(SyncRecordMapper.recordID(for: $0)) })
            applyRemote(deletions: remoteDeleted, fields: [:], engine: engine)
        }
        engine.state.add(pendingRecordZoneChanges: requeue.map { .saveRecord(SyncRecordMapper.recordID(for: $0)) })
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
        } catch { Self.log.error("Could not list models to clear: \(error)") }
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
            Self.log.error("Sync save failed: \(error)")
        }
    }

    // MARK: - Engine setup

    private func startEngine() {
        try? FileManager.default.removeItem(at: assetDirectory)  // leftovers of sends that never got a result
        let saved = loadState()
        let database = CKContainer(identifier: Self.containerID).privateCloudDatabase
        let engine = CKSyncEngine(CKSyncEngine.Configuration(database: database, stateSerialization: saved, delegate: self))
        self.engine = engine
        tracker = LocalChangeTracker(context: modelContext) { [weak self] changes in
            self?.engine?.state.add(pendingRecordZoneChanges: changes)
        }
        NSApplication.shared.registerForRemoteNotifications()
        if saved == nil { queueEverything(on: engine) }
    }

    /// First enable and encryptedDataReset: the zone, every eligible clip, every pinboard, every entry of an eligible clip.
    private func queueEverything(on engine: CKSyncEngine) {
        var ids: [UUID] = []
        do {
            // contentTypeRaw first: rawData is external storage and reading it loads the blob.
            let clips = try modelContext.fetch(FetchDescriptor<ClipboardItem>())
                .filter { $0.contentTypeRaw != "fileURL" && $0.isSyncEligible }.map(\.id)
            let eligible = Set(clips)
            let boards = try modelContext.fetch(FetchDescriptor<Pinboard>()).map(\.id)
            let entries = try modelContext.fetch(FetchDescriptor<PinboardEntry>())
                .filter { $0.snapshot.map { eligible.contains($0.clipID) } ?? false }.map(\.id)
            ids = clips + boards + entries
        } catch {
            Self.log.error("Could not list records to upload: \(error)")
        }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: SyncRecordMapper.zoneID))])
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(SyncRecordMapper.recordID(for: $0)) })
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let stateURL, let data = try? Data(contentsOf: stateURL) else { return nil }
        do {
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            Self.log.error("Discarding unreadable sync state: \(error)")
            return nil
        }
    }

    private func writeState(_ state: CKSyncEngine.State.Serialization) {
        guard let stateURL else { return }
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Self.log.error("Could not write sync state: \(error)")
        }
    }

    private func removeAsset(of record: CKRecord) {
        guard let id = UUID(uuidString: record.recordID.recordName) else { return }
        try? FileManager.default.removeItem(at: SyncRecordMapper.assetURL(for: id, in: assetDirectory))
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
