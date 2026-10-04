import AppKit
import SwiftData
import XCTest

@MainActor
final class RemoteApplierTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var pending: Set<UUID> = []
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        pending = []
    }

    private var applier: RemoteApplier {
        RemoteApplier(context: context) { [unowned self] in self.pending.contains($0) }
    }

    private func clip(_ n: Int, hash: String = "h", dt: TimeInterval = 0, pinned: Bool = false,
                      title: String? = nil, type: String = "plainText", data: Data = Data("x".utf8),
                      universalClipboard: Bool = false) -> ClipSnapshot {
        ClipSnapshot(id: id(n), contentType: type, rawData: data, textContent: "text", userTitle: title,
                     sourceAppName: "App", sourceAppBundleId: "com.app", contentHash: hash,
                     copiedAt: t0.addingTimeInterval(dt), isPinned: pinned, fromUniversalClipboard: universalClipboard)
    }

    private func board(_ n: Int, name: String = "Board", order: Int = 1) -> PinboardSnapshot {
        PinboardSnapshot(id: id(n), name: name, displayOrder: order, createdAt: t0)
    }

    private func entry(_ n: Int, clip c: Int, board b: Int, order: Int = 3) -> EntrySnapshot {
        EntrySnapshot(id: id(n), clipID: id(c), pinboardID: id(b), displayOrder: order, addedAt: t0)
    }

    @discardableResult
    private func apply(clips: [ClipSnapshot] = [], pinboards: [PinboardSnapshot] = [], entries: [EntrySnapshot] = [],
                       deletions: [UUID] = [], systemFields: [UUID: Data] = [:]) throws -> RemoteApplier.Outcome {
        let out = applier.apply(clips: clips, pinboards: pinboards, entries: entries,
                                deletions: deletions, systemFields: systemFields)
        try context.save()
        return out
    }

    private func clips() throws -> [ClipboardItem] { try context.fetch(FetchDescriptor<ClipboardItem>()) }
    private func boards() throws -> [Pinboard] { try context.fetch(FetchDescriptor<Pinboard>()) }
    private func entries() throws -> [PinboardEntry] { try context.fetch(FetchDescriptor<PinboardEntry>()) }

    private func png() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: Upserts

    func testInsertsNewClipWithAllFieldsAndSystemFields() throws {
        let sys = Data([1, 2, 3])
        let out = try apply(clips: [clip(1, pinned: true, title: "T")], systemFields: [id(1): sys])
        let m = try XCTUnwrap(try clips().first)
        XCTAssertEqual(m.id, id(1))
        XCTAssertEqual(m.textContent, "text")
        XCTAssertEqual(m.userTitle, "T")
        XCTAssertEqual(m.sourceAppName, "App")
        XCTAssertEqual(m.sourceAppBundleId, "com.app")
        XCTAssertEqual(m.contentHash, "h")
        XCTAssertEqual(m.copiedAt, t0)
        XCTAssertTrue(m.isPinned)
        XCTAssertEqual(m.syncSystemFields, sys)
        XCTAssertEqual(out.touched, [id(1)])
    }

    func testUpdatesClipWithoutPendingSave() throws {
        try apply(clips: [clip(1, title: "old")])
        let out = try apply(clips: [clip(1, hash: "h2", title: "new")])
        XCTAssertEqual(try clips().count, 1)
        XCTAssertEqual(try clips().first?.userTitle, "new")
        XCTAssertEqual(try clips().first?.contentHash, "h2")
        XCTAssertEqual(out.touched, [id(1)])
    }

    func testPendingSaveKeepsLocalFieldsButStoresSystemFields() throws {
        try apply(clips: [clip(1, title: "local")])
        pending = [id(1)]
        let sys = Data([9])
        try apply(clips: [clip(1, title: "remote")], systemFields: [id(1): sys])
        XCTAssertEqual(try clips().first?.userTitle, "local")
        XCTAssertEqual(try clips().first?.syncSystemFields, sys)
    }

    func testUpsertsPinboard() throws {
        try apply(pinboards: [board(1, name: "A")], systemFields: [id(1): Data([4])])
        try apply(pinboards: [board(1, name: "B", order: 7)])
        let b = try XCTUnwrap(try boards().first)
        XCTAssertEqual(try boards().count, 1)
        XCTAssertEqual(b.name, "B")
        XCTAssertEqual(b.displayOrder, 7)
        XCTAssertEqual(b.syncSystemFields, Data([4]))
    }

    func testLinksEntryWhenClipAndPinboardExist() throws {
        let out = try apply(clips: [clip(1)], pinboards: [board(2)], entries: [entry(3, clip: 1, board: 2)])
        let e = try XCTUnwrap(try entries().first)
        XCTAssertEqual(e.id, id(3))
        XCTAssertEqual(e.clipboardItem?.id, id(1))
        XCTAssertEqual(e.pinboard?.id, id(2))
        XCTAssertEqual(e.displayOrder, 3)
        XCTAssertEqual(e.addedAt, t0)
        XCTAssertEqual(out.touched, [id(1), id(2), id(3)])
        XCTAssertTrue(out.orphans.isEmpty)
    }

    func testEntryWithMissingClipIsReturnedAsOrphan() throws {
        let snap = entry(3, clip: 1, board: 2)
        let out = try apply(pinboards: [board(2)], entries: [snap])
        XCTAssertEqual(out.orphans, [snap])
        XCTAssertTrue(try entries().isEmpty)
        XCTAssertFalse(out.touched.contains(id(3)))
    }

    func testOrphanLeavesExistingEntryUntouched() throws {
        try apply(clips: [clip(1)], pinboards: [board(2)], entries: [entry(3, clip: 1, board: 2, order: 3)])
        let moved = EntrySnapshot(id: id(3), clipID: id(99), pinboardID: id(2), displayOrder: 8, addedAt: t0.addingTimeInterval(5))
        let out = try apply(entries: [moved])
        XCTAssertEqual(out.orphans, [moved])
        let e = try XCTUnwrap(try entries().first)
        XCTAssertEqual(e.clipboardItem?.id, id(1))
        XCTAssertEqual(e.displayOrder, 3)
        XCTAssertEqual(e.addedAt, t0)
    }

    func testExistingEntryIsRelinkedAndUpdated() throws {
        try apply(clips: [clip(1, hash: "a"), clip(4, hash: "b")], pinboards: [board(2)],
                  entries: [entry(3, clip: 1, board: 2)])
        try apply(entries: [entry(3, clip: 4, board: 2, order: 9)])
        let e = try XCTUnwrap(try entries().first)
        XCTAssertEqual(e.clipboardItem?.id, id(4))
        XCTAssertEqual(e.displayOrder, 9)
    }

    func testLinkingEntryTouchesExistingPinboardNotInBatch() throws {
        try apply(clips: [clip(1)], pinboards: [board(2)])
        let out = try apply(entries: [entry(3, clip: 1, board: 2)])
        XCTAssertEqual(out.touched, [id(2), id(3)])
    }

    func testRelinkTouchesOldAndNewPinboard() throws {
        try apply(clips: [clip(1)], pinboards: [board(2), board(4)], entries: [entry(3, clip: 1, board: 2)])
        let out = try apply(entries: [entry(3, clip: 1, board: 4)])
        XCTAssertEqual(try entries().first?.pinboard?.id, id(4))
        XCTAssertEqual(out.touched, [id(2), id(3), id(4)])
    }

    func testSameBatchLoserEntryMovesToSurvivor() throws {
        try apply(clips: [clip(1)])
        let out = try apply(clips: [clip(2, dt: 5)], pinboards: [board(3)], entries: [entry(4, clip: 2, board: 3)])
        XCTAssertTrue(out.orphans.isEmpty)
        XCTAssertEqual(try clips().map(\.id), [id(1)])
        XCTAssertEqual(try entries().first?.clipboardItem?.id, id(1))
        XCTAssertTrue(out.saves.contains(id(4)))
        XCTAssertTrue(out.deletes.contains(id(2)))
    }

    // MARK: Deletions

    func testDeletingClipRemovesItsEntries() throws {
        try apply(clips: [clip(1)], pinboards: [board(2)], entries: [entry(3, clip: 1, board: 2)])
        let out = try apply(deletions: [id(1)])
        XCTAssertTrue(try clips().isEmpty)
        XCTAssertTrue(try entries().isEmpty)
        XCTAssertEqual(try boards().count, 1)
        XCTAssertEqual(out.touched, [id(1), id(2), id(3)])
    }

    func testDeletingPinboardCascadesEntries() throws {
        try apply(clips: [clip(1)], pinboards: [board(2)], entries: [entry(3, clip: 1, board: 2)])
        try apply(deletions: [id(2)])
        XCTAssertTrue(try boards().isEmpty)
        XCTAssertTrue(try entries().isEmpty)
        XCTAssertEqual(try clips().count, 1)
    }

    func testTouchedIncludesCascadedPinboardEntries() throws {
        try apply(clips: [clip(1)], pinboards: [board(2)], entries: [entry(3, clip: 1, board: 2)])
        let out = try apply(deletions: [id(2)])
        XCTAssertEqual(out.touched, [id(2), id(3)])
    }

    func testDeletionOfUnknownIDIsNoOp() throws {
        try apply(clips: [clip(1)])
        let out = try apply(deletions: [id(77)])
        XCTAssertEqual(out, RemoteApplier.Outcome())
        XCTAssertEqual(try clips().count, 1)
    }

    func testDeletingEntryById() throws {
        try apply(clips: [clip(1)], pinboards: [board(2)], entries: [entry(3, clip: 1, board: 2)])
        let out = try apply(deletions: [id(3)])
        XCTAssertTrue(try entries().isEmpty)
        XCTAssertEqual(out.touched, [id(2), id(3)])
    }

    // MARK: Thumbnails

    func testIncomingImageGetsThumbnail() throws {
        try apply(clips: [clip(1, type: "image", data: try png())])
        let thumb = try XCTUnwrap(try clips().first?.thumbnailData)
        XCTAssertNotNil(NSImage(data: thumb))
    }

    func testIncomingFileClipGetsThumbnailFromItsImageFile() throws {
        let bundle = try FileBundle.encode([(name: "a.txt", data: Data("a".utf8), uti: "public.plain-text"),
                                            (name: "b.png", data: try png(), uti: "public.png")])
        try apply(clips: [clip(1, type: "files", data: bundle)])
        let thumb = try XCTUnwrap(try clips().first?.thumbnailData)
        XCTAssertNotNil(NSImage(data: thumb))
    }

    // MARK: File manifests

    private func fileClip(_ n: Int, names: [String]) throws -> ClipSnapshot {
        let bundle = try FileBundle.encode(names.map { (name: $0, data: Data($0.utf8), uti: "public.plain-text") })
        var s = clip(n, type: "files", data: bundle)
        s.fileManifest = FileBundle.manifestJSON(bundle)
        return s
    }

    func testIncomingFileClipStoresItsManifest() throws {
        let s = try fileClip(1, names: ["a.txt", "bb.txt"])
        try apply(clips: [s])
        let m = try XCTUnwrap(try clips().first)
        XCTAssertEqual(m.fileManifestData, s.fileManifest)
        XCTAssertEqual(m.fileManifest?.map(\.name), ["a.txt", "bb.txt"])
        XCTAssertEqual(m.fileManifest?.map(\.size), [5, 6])

        // A changed clip from the server replaces it.
        try apply(clips: [try fileClip(1, names: ["c.txt"])])
        XCTAssertEqual(try clips().first?.fileManifest?.map(\.name), ["c.txt"])
    }

    func testOtherClipsHaveNoManifest() throws {
        try apply(clips: [clip(1)])
        XCTAssertNil(try clips().first?.fileManifestData)
        XCTAssertNil(try clips().first?.fileManifest)
    }

    // MARK: Duplicate merges

    func testUniversalClipboardDuplicateMerges() throws {
        try apply(clips: [clip(2, dt: 10, pinned: true)])
        let out = try apply(clips: [clip(1, dt: 0, title: "T")])
        let all = try clips()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, id(1))
        XCTAssertEqual(all.first?.isPinned, true)
        XCTAssertEqual(all.first?.userTitle, "T")
        XCTAssertEqual(out.saves, [id(1)])
        XCTAssertEqual(out.deletes, [id(2)])
        XCTAssertEqual(out.touched, [id(1), id(2)])
    }

    func testIncomingLoserIsUpsertedAndDeletedInSameApply() throws {
        try apply(clips: [clip(1)])
        let out = try apply(clips: [clip(2, dt: 5)])
        XCTAssertEqual(try clips().map(\.id), [id(1)])
        XCTAssertEqual(out.deletes, [id(2)])
        XCTAssertTrue(out.touched.contains(id(2)))
    }

    func testMergeMovesLoserEntryToSurvivor() throws {
        try apply(clips: [clip(1), clip(2, hash: "z", dt: 5)], pinboards: [board(3)],
                  entries: [entry(6, clip: 2, board: 3)])
        let out = try apply(clips: [clip(2, dt: 5)])  // hash becomes "h": now a duplicate of clip 1
        XCTAssertEqual(try clips().filter { $0.contentHash == "h" }.map(\.id), [id(1)])
        let moved = try XCTUnwrap(try entries().first { $0.id == id(6) })
        XCTAssertEqual(moved.clipboardItem?.id, id(1))
        XCTAssertTrue(out.saves.contains(id(6)))
        XCTAssertTrue(out.touched.contains(id(6)))
    }

    func testMergeDropsLoserEntryWhenSurvivorAlreadyPinned() throws {
        try apply(clips: [clip(1, hash: "y"), clip(2, hash: "z", dt: 5)], pinboards: [board(3)],
                  entries: [entry(4, clip: 1, board: 3), entry(5, clip: 2, board: 3)])
        XCTAssertEqual(try clips().count, 2, "different hashes at first")
        // Re-deliver both with the same hash to trigger the merge.
        let out = try apply(clips: [clip(1, hash: "h"), clip(2, hash: "h", dt: 5)])
        XCTAssertEqual(try clips().map(\.id), [id(1)])
        XCTAssertEqual(try entries().map(\.id), [id(4)])
        XCTAssertTrue(out.deletes.contains(id(5)))
        XCTAssertTrue(out.deletes.contains(id(2)))
        XCTAssertTrue(out.touched.contains(id(5)))
    }

    func testMergedSurvivorTakesLatestCopiedAt() throws {
        try apply(clips: [clip(1)])  // local, older, smaller UUID: survives
        try apply(clips: [clip(2, dt: 30)])  // incoming re-copy, newer, larger UUID: loses
        let survivor = try XCTUnwrap(try clips().first)
        XCTAssertEqual(try clips().count, 1)
        XCTAssertEqual(survivor.id, id(1))
        XCTAssertEqual(survivor.copiedAt, t0.addingTimeInterval(30))
    }

    // MARK: Arrivals (what the iPhone announces)

    func testArrivalsAreOnlyNewClips() throws {
        let first = try apply(clips: [clip(1)], pinboards: [board(2)])
        XCTAssertEqual(first.arrivals, [id(1)], "a new clip arrives; a pinboard is not a clip")
        let again = try apply(clips: [clip(1, title: "renamed")])
        XCTAssertTrue(again.arrivals.isEmpty, "an update of a clip this device has is not an arrival")
    }

    /// Universal Clipboard: this device already has the copy, and the other device's record merges into it.
    func testDuplicateOfALocalCopyIsNotAnArrival() throws {
        try apply(clips: [clip(2)])  // local copy, larger UUID: the incoming one survives
        XCTAssertTrue(try apply(clips: [clip(1, dt: 5)]).arrivals.isEmpty, "incoming survivor")
        try apply(clips: [clip(3, hash: "k")])  // local copy, smaller UUID: the incoming one loses
        XCTAssertTrue(try apply(clips: [clip(4, hash: "k", dt: 5)]).arrivals.isEmpty, "incoming loser")
    }

    /// Two other devices copied the same thing within 60 s: the copies merge, and the iPhone announces one clip.
    func testTwoNewCopiesThatMergeAreOneArrival() throws {
        let out = try apply(clips: [clip(1), clip(2, dt: 5)])
        XCTAssertEqual(try clips().map(\.id), [id(1)])
        XCTAssertEqual(out.arrivals, [id(1)])
    }

    /// A new copy that merges with another new copy, which itself merged with this device's copy, is still a copy
    /// this device had. The times make 1 and 2 duplicates only once 2 took 3's later time, in either fetch order.
    func testNewCopyMergedThroughALocalCopyIsNotAnArrival() throws {
        try apply(clips: [clip(3, dt: 60)])  // local copy
        XCTAssertTrue(try apply(clips: [clip(2, dt: 0), clip(1, dt: 120)]).arrivals.isEmpty)
        XCTAssertEqual(try clips().map(\.id), [id(1)])
    }

    /// The user's own iPhone copy, captured by the Mac from Universal Clipboard and synced back.
    func testUniversalClipboardCopyIsNotAnArrival() throws {
        XCTAssertTrue(try apply(clips: [clip(1, universalClipboard: true)]).arrivals.isEmpty)
        XCTAssertEqual(try clips().count, 1, "still stored")
    }

    /// Two Macs: a copy on one reaches the other through Universal Clipboard, which captures it flagged. The real copy
    /// is still announced once, whichever record survives the merge and whichever arrives first.
    func testCopyRelayedByAnotherMacIsStillOneArrival() throws {
        XCTAssertEqual(try apply(clips: [clip(1), clip(2, universalClipboard: true)]).arrivals, [id(1)], "real copy survives")
        XCTAssertEqual(try apply(clips: [clip(3, hash: "k", universalClipboard: true), clip(4, hash: "k")]).arrivals, [id(3)],
                       "relayed copy survives")
        XCTAssertTrue(try apply(clips: [clip(5, hash: "m", universalClipboard: true)]).arrivals.isEmpty)
        XCTAssertEqual(try apply(clips: [clip(6, hash: "m", dt: 5)]).arrivals, [id(5)], "relayed copy came first")
        // A real copy wins the flag, so every device converges on a clip that is announced like any other.
        XCTAssertEqual(try clips().filter { [id(3), id(5)].contains($0.id) }.map(\.fromUniversalClipboard), [false, false])
    }

    /// Two Macs both capture the user's own iPhone copy from Universal Clipboard: the merged clip stays relayed.
    func testTwoRelayedCopiesStayRelayedAndUnannounced() throws {
        XCTAssertTrue(try apply(clips: [clip(1, universalClipboard: true), clip(2, universalClipboard: true)]).arrivals.isEmpty)
        XCTAssertEqual(try clips().map(\.fromUniversalClipboard), [true])
        XCTAssertTrue(try apply(clips: [clip(3, universalClipboard: true)]).arrivals.isEmpty, "the second copy came later")
    }

    func testUniversalClipboardFlagIsStoredOnInsertAndUpdate() throws {
        try apply(clips: [clip(1, universalClipboard: true)])
        XCTAssertEqual(try clips().first?.fromUniversalClipboard, true)
        XCTAssertEqual(try clips().first?.snapshot.fromUniversalClipboard, true, "and uploads with the clip")
        try apply(clips: [clip(1, universalClipboard: false)])
        XCTAssertEqual(try clips().first?.fromUniversalClipboard, false)
    }

    func testNoMergeAt61Seconds() throws {
        try apply(clips: [clip(1)])
        let out = try apply(clips: [clip(2, dt: 61)])
        XCTAssertEqual(try clips().count, 2)
        XCTAssertTrue(out.saves.isEmpty)
        XCTAssertTrue(out.deletes.isEmpty)
    }

    // MARK: Bookkeeping

    func testTouchedCoversEveryChangedID() throws {
        try apply(clips: [clip(1, hash: "a"), clip(7, hash: "c")], pinboards: [board(2)],
                  entries: [entry(3, clip: 1, board: 2)])
        let out = try apply(clips: [clip(4, hash: "b")], pinboards: [board(5)],
                            entries: [entry(6, clip: 4, board: 5)], deletions: [id(7)],
                            systemFields: [id(1): Data([1])])
        XCTAssertEqual(out.touched, [id(1), id(4), id(5), id(6), id(7)])
    }

    func testClearSystemFieldsResetsEveryModel() throws {
        try apply(clips: [clip(1)], pinboards: [board(2)], entries: [entry(3, clip: 1, board: 2)],
                  systemFields: [id(1): Data([1]), id(2): Data([2]), id(3): Data([3])])
        XCTAssertNotNil(try clips().first?.syncSystemFields)
        RemoteApplier.clearSystemFields(in: context)
        try context.save()
        XCTAssertNil(try clips().first?.syncSystemFields)
        XCTAssertNil(try boards().first?.syncSystemFields)
        XCTAssertNil(try entries().first?.syncSystemFields)
    }

    func testDeleteAllRemovesEverythingAndReportsIDs() throws {
        try apply(clips: [clip(1, hash: "a"), clip(2, hash: "b")], pinboards: [board(3)],
                  entries: [entry(4, clip: 1, board: 3)])
        let ids = RemoteApplier.deleteAll(in: context)
        try context.save()
        XCTAssertEqual(try clips().count, 0)
        XCTAssertEqual(try boards().count, 0)
        XCTAssertEqual(try entries().count, 0)
        XCTAssertEqual(ids, [id(1), id(2), id(3), id(4)])
    }

    // MARK: Uploadable ids

    /// 1 unconfirmed clip, 2 confirmed clip, 3 fileURL clip, 4 pinboard, 5 entry of clip 1, 6 entry of clip 3.
    private func seedUploadable() throws {
        try apply(clips: [clip(1, hash: "a"), clip(2, hash: "b"), clip(3, hash: "c", type: "fileURL")],
                  pinboards: [board(4)],
                  entries: [entry(5, clip: 1, board: 4), entry(6, clip: 3, board: 4)],
                  systemFields: [id(2): Data([1])])
    }

    func testUploadableIDsUnconfirmedOnly() throws {
        try seedUploadable()
        let ids = try RemoteApplier.uploadableIDs(in: context, onlyUnconfirmed: true)
        XCTAssertEqual(Set(ids), [id(1), id(4), id(5)])
    }

    func testUploadableIDsAllSkipsFileClips() throws {
        try seedUploadable()
        let ids = try RemoteApplier.uploadableIDs(in: context, onlyUnconfirmed: false)
        XCTAssertEqual(Set(ids), [id(1), id(2), id(4), id(5)])
    }
}
