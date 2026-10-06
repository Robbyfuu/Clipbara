import AppKit
import CloudKit
import SwiftData
import XCTest

/// `AppIdentity` through the same local paths as clips: the tracker uploads it, the applier writes it, and the
/// re-queue and wipe lists include it.
@MainActor
final class AppIdentitySyncTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var tracker: LocalChangeTracker!
    private var changes: [CKSyncEngine.PendingRecordZoneChange] = []
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        let schema = Schema(StoreSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        context = container.mainContext
        changes = []
        tracker = LocalChangeTracker(context: context) { [unowned self] in self.changes += $0 }
    }

    private func identity(_ bundleId: String = "com.apple.Safari", dt: TimeInterval = 0) -> AppIdentity {
        AppIdentity(bundleId: bundleId, name: "Safari", iconPNG: Data([1, 2, 3]), colorHex: "#1E90FF",
                    updatedAt: t0.addingTimeInterval(dt))
    }

    /// A record another Mac published: its own random id.
    private func snapshot(_ bundleId: String = "com.apple.Safari", name: String = "Safari", dt: TimeInterval = 0,
                          id: UUID = UUID()) -> AppIdentitySnapshot {
        AppIdentitySnapshot(id: id, bundleId: bundleId, name: name, iconPNG: Data([4, 5]), colorHex: "#FFCC00",
                            updatedAt: t0.addingTimeInterval(dt))
    }

    private func recordID(_ m: AppIdentity) -> CKRecord.ID { SyncRecordMapper.recordID(for: m.id) }

    private func identities() throws -> [AppIdentity] { try context.fetch(FetchDescriptor<AppIdentity>()) }

    private var applier: RemoteApplier { RemoteApplier(context: context) { _ in false } }

    // MARK: Tracker

    /// Ruling R6: under its random id, like a clip, never a name derived from the bundle id.
    func testPublishQueuesASaveUnderItsRandomID() throws {
        let m = identity()
        context.insert(m)
        try context.save()
        XCTAssertEqual(changes, [.saveRecord(SyncRecordMapper.recordID(named: m.id.uuidString))])
    }

    func testRefreshQueuesASave() throws {
        let m = identity()
        context.insert(m)
        try context.save()
        changes = []
        m.colorHex = "#000000"
        try context.save()
        XCTAssertEqual(changes, [.saveRecord(recordID(m))])
    }

    func testDeleteQueuesADelete() throws {
        let m = identity()
        context.insert(m)
        try context.save()
        changes = []
        context.delete(m)
        try context.save()
        XCTAssertEqual(changes, [.deleteRecord(recordID(m))])
    }

    func testSyncWritesAreSuppressedByLocalID() throws {
        let m = identity()
        context.insert(m)
        try tracker.suppressing([m.id]) { try context.save() }
        XCTAssertEqual(changes, [])
    }

    /// The iPhone's tracker (`publishesHere` is false there): an identity it saves or deletes never uploads.
    func testPhoneTrackerNeverQueuesIdentities() throws {
        let phone = LocalChangeTracker(context: context, uploadsIdentities: false) { [unowned self] in self.changes += $0 }
        tracker = nil
        let m = identity()
        context.insert(m)
        let clip = ClipboardItem(contentType: .plainText, rawData: Data("x".utf8), textContent: "x", contentHash: "h")
        context.insert(clip)
        try context.save()
        XCTAssertEqual(changes, [.saveRecord(SyncRecordMapper.recordID(for: clip.id))], "clips still upload")
        changes = []
        context.delete(m)
        try context.save()
        XCTAssertEqual(changes, [])
        _ = phone
    }

    // MARK: Applier

    func testApplyInsertsAFetchedIdentity() throws {
        let s = snapshot()
        let out = applier.apply(clips: [], pinboards: [], entries: [], identities: [s], deletions: [], systemFields: [:])
        try context.save()
        let m = try XCTUnwrap(try identities().first)
        XCTAssertEqual(m.snapshot, s)
        XCTAssertEqual(m.id, s.id, "the record's id, kept as the local one")
        XCTAssertEqual(out.touched, [m.id])
        XCTAssertEqual(out.saves, [], "an identity never merges, so it queues nothing")
    }

    /// The same record again: only a newer copy overwrites it.
    func testNewerCopyOfTheSameRecordWins() throws {
        let m = identity(dt: 100)
        context.insert(m)
        try context.save()
        _ = applier.apply(clips: [], pinboards: [], entries: [], identities: [snapshot(name: "Older", dt: 50, id: m.id)],
                          deletions: [], systemFields: [:])
        XCTAssertEqual(try identities().first?.name, "Safari")
        _ = applier.apply(clips: [], pinboards: [], entries: [], identities: [snapshot(name: "Newer", dt: 150, id: m.id)],
                          deletions: [], systemFields: [:])
        XCTAssertEqual(try identities().first?.name, "Newer")
        XCTAssertEqual(try identities().count, 1)
    }

    func testApplyStoresSystemFieldsAndDeletes() throws {
        let s = snapshot(), id = s.id
        _ = applier.apply(clips: [], pinboards: [], entries: [], identities: [s], deletions: [],
                          systemFields: [id: Data([9])])
        try context.save()
        XCTAssertEqual(try identities().first?.syncSystemFields, Data([9]))
        let out = applier.apply(clips: [], pinboards: [], entries: [], deletions: [id], systemFields: [:])
        try context.save()
        XCTAssertEqual(try identities().count, 0)
        XCTAssertEqual(out.touched, [id])
    }

    /// The iPhone redraws its app icons only after an apply that changed an identity.
    func testOutcomeSaysWhenIdentitiesChanged() throws {
        let clip = ClipSnapshot(id: UUID(), contentType: ContentType.plainText.rawValue, rawData: Data("x".utf8),
                                textContent: "x", userTitle: nil, sourceAppName: nil, sourceAppBundleId: nil,
                                contentHash: "h", copiedAt: t0, isPinned: false)
        XCTAssertFalse(applier.apply(clips: [clip], pinboards: [], entries: [], deletions: [], systemFields: [:])
            .identitiesChanged, "clips only")
        let s = snapshot()
        XCTAssertTrue(applier.apply(clips: [], pinboards: [], entries: [], identities: [s], deletions: [], systemFields: [:])
            .identitiesChanged)
        try context.save()
        XCTAssertFalse(applier.apply(clips: [], pinboards: [], entries: [], identities: [s], deletions: [], systemFields: [:])
            .identitiesChanged, "the same identity again")
        let id = try XCTUnwrap(try identities().first?.id)
        XCTAssertTrue(applier.apply(clips: [], pinboards: [], entries: [], deletions: [id], systemFields: [:])
            .identitiesChanged)
    }

    // MARK: One identity per app (ruling R6)

    /// Two Macs published one app, each under its own random name: the newest survives, and the Mac deletes the other.
    func testANewerRecordForTheSameAppReplacesTheLocalOne() throws {
        let local = identity(dt: 0)
        context.insert(local)
        try context.save()
        let newer = snapshot(name: "Newer", dt: 100)
        let out = applier.apply(clips: [], pinboards: [], entries: [], identities: [newer], deletions: [],
                                systemFields: [newer.id: Data([7])])
        try context.save()
        XCTAssertEqual(try identities().map(\.id), [newer.id])
        XCTAssertEqual(try identities().first?.name, "Newer")
        XCTAssertEqual(try identities().first?.syncSystemFields, Data([7]))
        XCTAssertEqual(out.deletes, [local.id], "the Mac queues the loser's delete")
        XCTAssertTrue(out.touched.isSuperset(of: [local.id, newer.id]))
        XCTAssertTrue(out.identitiesChanged)
    }

    func testAnOlderRecordForTheSameAppIsDeleted() throws {
        let local = identity(dt: 100)
        context.insert(local)
        try context.save()
        let older = snapshot(name: "Older", dt: 0)
        let out = applier.apply(clips: [], pinboards: [], entries: [], identities: [older], deletions: [],
                                systemFields: [older.id: Data([7])])
        try context.save()
        XCTAssertEqual(try identities().map(\.id), [local.id])
        XCTAssertEqual(try identities().first?.name, "Safari")
        XCTAssertNil(try identities().first?.syncSystemFields, "the loser's fields never land on the survivor")
        XCTAssertEqual(out.deletes, [older.id], "the Mac queues the loser's delete")
        XCTAssertFalse(out.identitiesChanged)
    }

    /// The iPhone never uploads an identity, so it only drops its copy of the loser.
    func testThePhoneDropsTheLoserWithoutQueueingADelete() throws {
        let local = identity(dt: 0)
        context.insert(local)
        try context.save()
        let phone = RemoteApplier(context: context, deletesLosingIdentities: false) { _ in false }
        let newer = snapshot(name: "Newer", dt: 100), older = snapshot(name: "Older", dt: -100)
        let out = phone.apply(clips: [], pinboards: [], entries: [], identities: [newer, older], deletions: [],
                              systemFields: [:])
        try context.save()
        XCTAssertEqual(try identities().map(\.id), [newer.id])
        XCTAssertEqual(out.deletes, [])
    }

    /// Two records for one app in one fetch, in either order, and a tie: every device keeps the same one.
    func testATieKeepsTheSameRecordOnEveryDevice() throws {
        let low = snapshot(name: "Low", id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
        let high = snapshot(name: "High", id: try XCTUnwrap(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000000")))
        for order in [[low, high], [high, low]] {
            _ = RemoteApplier.deleteAll(in: context)
            try context.save()
            let out = applier.apply(clips: [], pinboards: [], entries: [], identities: order, deletions: [], systemFields: [:])
            try context.save()
            XCTAssertEqual(try identities().map(\.id), [low.id], "order \(order.map(\.name))")
            XCTAssertEqual(out.deletes, [high.id], "order \(order.map(\.name))")
        }
    }

    // MARK: Re-queue, reset and wipe

    func testUploadableRecordIDsIncludeIdentities() throws {
        let confirmed = identity("com.apple.Notes")
        confirmed.syncSystemFields = Data([1])
        context.insert(confirmed)
        let unconfirmed = identity()
        context.insert(unconfirmed)
        let clip = ClipboardItem(contentType: .plainText, rawData: Data("x".utf8), textContent: "x", contentHash: "h")
        context.insert(clip)
        try context.save()
        XCTAssertEqual(Set(try RemoteApplier.uploadableRecordIDs(in: context, onlyUnconfirmed: true)),
                       [recordID(unconfirmed), SyncRecordMapper.recordID(for: clip.id)])
        XCTAssertEqual(Set(try RemoteApplier.uploadableRecordIDs(in: context, onlyUnconfirmed: false)),
                       [recordID(unconfirmed), recordID(confirmed), SyncRecordMapper.recordID(for: clip.id)])
        // The iPhone re-queues only its clips, pinboards and entries.
        XCTAssertEqual(try RemoteApplier.uploadableRecordIDs(in: context, onlyUnconfirmed: false, includingIdentities: false),
                       [SyncRecordMapper.recordID(for: clip.id)])
    }

    func testClearSystemFieldsAndDeleteAllCoverIdentities() throws {
        let m = identity()
        m.syncSystemFields = Data([1])
        context.insert(m)
        try context.save()
        RemoteApplier.clearSystemFields(in: context)
        XCTAssertNil(m.syncSystemFields)
        XCTAssertEqual(RemoteApplier.deleteAll(in: context), [m.id])
        try context.save()
        XCTAssertEqual(try identities().count, 0)
    }

    // MARK: Icons

    private func png(side: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// The keyboard decodes each app's 128 px icon once, at no more than 28 px, and only for the apps it asks for.
    func testIconsDecodeSmallAndOnlyTheRequestedApps() throws {
        let icon = try png(side: 128)
        for bundle in ["com.apple.Safari", "com.apple.Notes"] {
            context.insert(AppIdentity(bundleId: bundle, name: bundle, iconPNG: icon, colorHex: "#FFFFFF"))
        }
        try context.save()
        let icons = try AppIdentity.icons(for: ["com.apple.Safari", "com.unknown.app"], maxPixels: 28, in: context)
        XCTAssertEqual(Set(icons.keys), ["com.apple.Safari"])
        XCTAssertLessThanOrEqual(try XCTUnwrap(icons["com.apple.Safari"]).width, 28)
    }
}
