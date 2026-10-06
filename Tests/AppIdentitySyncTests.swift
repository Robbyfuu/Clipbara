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

    private func snapshot(_ bundleId: String = "com.apple.Safari", name: String = "Safari", dt: TimeInterval = 0) -> AppIdentitySnapshot {
        AppIdentitySnapshot(bundleId: bundleId, name: name, iconPNG: Data([4, 5]), colorHex: "#FFCC00",
                            updatedAt: t0.addingTimeInterval(dt))
    }

    private func recordID(_ bundleId: String = "com.apple.Safari") -> CKRecord.ID {
        SyncRecordMapper.recordID(named: AppIdentity.recordName(for: bundleId))
    }

    private func identities() throws -> [AppIdentity] { try context.fetch(FetchDescriptor<AppIdentity>()) }

    private var applier: RemoteApplier { RemoteApplier(context: context) { _ in false } }

    // MARK: Tracker

    func testPublishQueuesASaveUnderTheStableName() throws {
        context.insert(identity())
        try context.save()
        XCTAssertEqual(changes, [.saveRecord(recordID())])
    }

    func testRefreshQueuesASave() throws {
        let m = identity()
        context.insert(m)
        try context.save()
        changes = []
        m.colorHex = "#000000"
        try context.save()
        XCTAssertEqual(changes, [.saveRecord(recordID())])
    }

    func testDeleteQueuesADelete() throws {
        let m = identity()
        context.insert(m)
        try context.save()
        changes = []
        context.delete(m)
        try context.save()
        XCTAssertEqual(changes, [.deleteRecord(recordID())])
    }

    func testSyncWritesAreSuppressedByLocalID() throws {
        let m = identity()
        context.insert(m)
        try tracker.suppressing([AppIdentity.id(for: "com.apple.Safari")]) { try context.save() }
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
        let out = applier.apply(clips: [], pinboards: [], entries: [], identities: [snapshot()], deletions: [], systemFields: [:])
        try context.save()
        let m = try XCTUnwrap(try identities().first)
        XCTAssertEqual(m.snapshot, snapshot())
        XCTAssertEqual(m.id, AppIdentity.id(for: "com.apple.Safari"))
        XCTAssertEqual(out.touched, [m.id])
        XCTAssertEqual(out.saves, [], "an identity never merges, so it queues nothing")
    }

    /// Two Macs may publish one app: the newer one wins, whichever arrives last.
    func testNewerIdentityWins() throws {
        context.insert(identity(dt: 100))
        try context.save()
        _ = applier.apply(clips: [], pinboards: [], entries: [], identities: [snapshot(name: "Older", dt: 50)],
                          deletions: [], systemFields: [:])
        XCTAssertEqual(try identities().first?.name, "Safari")
        _ = applier.apply(clips: [], pinboards: [], entries: [], identities: [snapshot(name: "Newer", dt: 150)],
                          deletions: [], systemFields: [:])
        XCTAssertEqual(try identities().first?.name, "Newer")
        XCTAssertEqual(try identities().count, 1)
    }

    func testApplyStoresSystemFieldsAndDeletes() throws {
        let id = AppIdentity.id(for: "com.apple.Safari")
        _ = applier.apply(clips: [], pinboards: [], entries: [], identities: [snapshot()], deletions: [],
                          systemFields: [id: Data([9])])
        try context.save()
        XCTAssertEqual(try identities().first?.syncSystemFields, Data([9]))
        let out = applier.apply(clips: [], pinboards: [], entries: [], deletions: [id], systemFields: [:])
        try context.save()
        XCTAssertEqual(try identities().count, 0)
        XCTAssertEqual(out.touched, [id])
    }

    // MARK: Re-queue, reset and wipe

    func testUploadableRecordIDsIncludeIdentities() throws {
        let confirmed = identity("com.apple.Notes")
        confirmed.syncSystemFields = Data([1])
        context.insert(confirmed)
        context.insert(identity())
        let clip = ClipboardItem(contentType: .plainText, rawData: Data("x".utf8), textContent: "x", contentHash: "h")
        context.insert(clip)
        try context.save()
        XCTAssertEqual(Set(try RemoteApplier.uploadableRecordIDs(in: context, onlyUnconfirmed: true)),
                       [recordID(), SyncRecordMapper.recordID(for: clip.id)])
        XCTAssertEqual(Set(try RemoteApplier.uploadableRecordIDs(in: context, onlyUnconfirmed: false)),
                       [recordID(), recordID("com.apple.Notes"), SyncRecordMapper.recordID(for: clip.id)])
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
        XCTAssertEqual(RemoteApplier.deleteAll(in: context), [AppIdentity.id(for: "com.apple.Safari")])
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
