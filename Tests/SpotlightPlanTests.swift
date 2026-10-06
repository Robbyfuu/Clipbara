import SwiftData
import XCTest

/// Review focus 1 and 4: a secret never reaches Spotlight, and the index follows every delete.
@MainActor
final class SpotlightPlanTests: XCTestCase {
    private var containers: [ModelContainer] = []
    private var observer: SpotlightPlan.SaveObserver?
    /// What `observer` handed over, across saves.
    private var saved: Set<UUID> = [], deleted: Set<UUID> = []

    private func input(_ type: ContentType, text: String? = nil, ocr: String? = nil, linkTitle: String? = nil,
                       files: [String] = [], thumbnail: Bool = false, secret: Bool = false,
                       id: UUID = UUID()) -> SpotlightPlan.Input {
        SpotlightPlan.Input(id: id, contentType: type, text: text, ocrText: ocr, linkTitle: linkTitle, fileNames: files,
                            hasThumbnail: thumbnail, isSensitive: secret)
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        containers.append(container)
        return container.mainContext
    }

    private func text(_ text: String, type: ContentType = .plainText) -> ClipboardItem {
        ClipboardItem(contentType: type, rawData: Data(text.utf8), textContent: text,
                      contentHash: ClipCapture.hash(Data(text.utf8)))
    }

    /// Watches `context` the way `SpotlightIndexer` watches the main context.
    private func collect(_ context: ModelContext) {
        observer = SpotlightPlan.SaveObserver(context: context) { [unowned self] in
            saved.formUnion($0)
            deleted.formUnion($1)
        }
    }

    // MARK: Each type in or out

    func testTextIsIndexedByItsFirstLine() throws {
        let record = try XCTUnwrap(SpotlightPlan.record(for: input(.plainText, text: "\n  Grocery list\nmilk\neggs  ")))
        XCTAssertEqual(record.title, "Grocery list")
        XCTAssertEqual(record.summary, "milk\neggs", "the rest of the text, after the title")
        XCTAssertEqual(record.thumbnailSource, .none)
        XCTAssertNotNil(SpotlightPlan.record(for: input(.richText, text: "Rich")), "rich text is text")
        XCTAssertNotNil(SpotlightPlan.record(for: input(.html, text: "<b>Hi</b>")), "HTML is text")
    }

    func testEmptyTextIsNotIndexed() {
        XCTAssertNil(SpotlightPlan.record(for: input(.plainText, text: " \n\t ")))
        XCTAssertNil(SpotlightPlan.record(for: input(.plainText, text: nil)))
    }

    func testTitleAndSummaryLimits() throws {
        let line = String(repeating: "a", count: 500), rest = String(repeating: "b", count: 500)
        let record = try XCTUnwrap(SpotlightPlan.record(for: input(.plainText, text: line + "\n" + rest)))
        XCTAssertEqual(record.title, String(repeating: "a", count: 80))
        XCTAssertEqual(record.summary.count, 300)
        XCTAssertTrue(record.summary.hasPrefix("aaa"), "a long first line goes on in the summary")
        let image = try XCTUnwrap(SpotlightPlan.record(for: input(.image, ocr: line)))
        XCTAssertEqual(image.title.count, 80)
        let files = try XCTUnwrap(SpotlightPlan.record(for: input(.files, files: Array(repeating: line, count: 3))))
        XCTAssertLessThanOrEqual(files.title.count, 80)
        XCTAssertLessThanOrEqual(files.summary.count, 300)
    }

    func testLinkIsIndexedByItsPageTitleOrURL() throws {
        let url = "https://copyd.app/docs"
        let titled = try XCTUnwrap(SpotlightPlan.record(for: input(.url, text: url, linkTitle: "Copyd Docs", thumbnail: true)))
        XCTAssertEqual(titled.title, "Copyd Docs")
        XCTAssertEqual(titled.summary, url, "the URL is searchable too")
        XCTAssertEqual(titled.thumbnailSource, .link)
        let bare = try XCTUnwrap(SpotlightPlan.record(for: input(.url, text: url, linkTitle: "  ")))
        XCTAssertEqual(bare.title, url)
        XCTAssertEqual(bare.summary, "", "never the URL twice")
        XCTAssertEqual(bare.thumbnailSource, .none)
    }

    func testImageIsIndexedOnlyWithText() throws {
        let record = try XCTUnwrap(SpotlightPlan.record(for: input(.image, ocr: "Invoice 42\nTotal $10", thumbnail: true)))
        XCTAssertEqual(record.title, "Image \u{00b7} Invoice 42")
        XCTAssertEqual(record.summary, "Total $10")
        XCTAssertEqual(record.thumbnailSource, .image)
        XCTAssertNil(SpotlightPlan.record(for: input(.image, thumbnail: true)), "no text read")
        XCTAssertNil(SpotlightPlan.record(for: input(.image, ocr: " \n", thumbnail: true)), "no text found")
    }

    /// The test bundle carries the iPhone's catalog; its `es.lproj` picks Spanish whatever this Mac's language is.
    func testImageTitleIsLocalized() throws {
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "es", ofType: "lproj"))
        let es = try XCTUnwrap(Bundle(path: path))
        let record = try XCTUnwrap(SpotlightPlan.record(for: input(.image, ocr: "Factura"), bundle: es))
        XCTAssertEqual(record.title, "Imagen \u{00b7} Factura")
    }

    func testFilesAreIndexedByName() throws {
        let one = try XCTUnwrap(SpotlightPlan.record(for: input(.files, files: ["Report.pdf"])))
        XCTAssertEqual(one.title, "Report.pdf")
        XCTAssertEqual(one.summary, "")
        let many = try XCTUnwrap(SpotlightPlan.record(for: input(.files, files: ["a.png", "b.png", "c.txt"])))
        XCTAssertEqual(many.title, "a.png")
        XCTAssertEqual(many.summary, "b.png, c.txt")
        XCTAssertNil(SpotlightPlan.record(for: input(.files)), "no names")
    }

    func testColorsAndUnknownAreNotIndexed() {
        XCTAssertNil(SpotlightPlan.record(for: input(.color, text: "#F8D14F")))
        XCTAssertNil(SpotlightPlan.record(for: input(.unknown, text: "something")))
    }

    func testSecretsAreNeverIndexed() {
        let secrets = [input(.plainText, text: FakeSecret.stripe, secret: true),
                       input(.url, text: "https://copyd.app/?k=1", linkTitle: "Copyd", thumbnail: true, secret: true),
                       input(.image, ocr: FakeSecret.aws, thumbnail: true, secret: true),
                       input(.files, files: ["keys.txt"], secret: true)]
        for secret in secrets { XCTAssertNil(SpotlightPlan.record(for: secret), "\(secret.contentType)") }
        let plain = input(.plainText, text: "note")
        let out = SpotlightPlan.changes(saved: secrets + [plain], deleted: [])
        XCTAssertEqual(out.upsert.map(\.id), [plain.id])
        XCTAssertEqual(Set(out.delete), Set(secrets.map(\.id)), "a clip saved as a secret leaves the index")
    }

    /// Text read in an image is the image's only text: when it reads as a secret, the image stays out.
    func testImageWhoseTextIsASecretIsNotIndexed() {
        XCTAssertNil(SpotlightPlan.record(for: input(.image, ocr: FakeSecret.aws, thumbnail: true)))
        XCTAssertNil(SpotlightPlan.record(for: input(.image, ocr: "\n " + FakeSecret.stripe + " \n", thumbnail: true)))
        XCTAssertNotNil(SpotlightPlan.record(for: input(.image, ocr: "Invoice 42", thumbnail: true)))
    }

    /// Text or a link that reads as a secret stays out whatever "Protect secrets" says, like an image's text: Spotlight
    /// is outside the app, where nothing can be masked.
    func testTextOrLinkThatIsASecretIsNotIndexed() {
        XCTAssertNil(SpotlightPlan.record(for: input(.plainText, text: FakeSecret.stripe)))
        XCTAssertNil(SpotlightPlan.record(for: input(.richText, text: "export TOKEN=" + FakeSecret.github)))
        XCTAssertNil(SpotlightPlan.record(for: input(.html, text: "\n " + FakeSecret.aws + " \n")))
        XCTAssertNil(SpotlightPlan.record(for: input(.url, text: FakeSecret.jwt, linkTitle: "Copyd")))
        XCTAssertNotNil(SpotlightPlan.record(for: input(.plainText, text: "Grocery list")))
        XCTAssertNotNil(SpotlightPlan.record(for: input(.url, text: "https://copyd.app/docs")))
    }

    // MARK: Transitions

    func testOCRTextRemovedBecomesADelete() {
        let id = UUID()
        XCTAssertEqual(SpotlightPlan.changes(saved: [input(.image, ocr: "Hello", id: id)], deleted: []).upsert.map(\.id), [id])
        let out = SpotlightPlan.changes(saved: [input(.image, ocr: nil, id: id)], deleted: [])
        XCTAssertEqual(out.upsert, [])
        XCTAssertEqual(out.delete, [id])
    }

    func testDeletedIdsAreRemoved() {
        let kept = input(.plainText, text: "kept"), gone = UUID(), insertedAndDeleted = input(.plainText, text: "brief")
        let out = SpotlightPlan.changes(saved: [kept, insertedAndDeleted], deleted: [gone, insertedAndDeleted.id])
        XCTAssertEqual(out.upsert.map(\.id), [kept.id])
        XCTAssertEqual(Set(out.delete), [gone, insertedAndDeleted.id], "a delete wins over a save in the same save")
    }

    /// C4: an edit into a secret deletes the clip and inserts a new local one. The old id leaves the index, the new
    /// one never enters it.
    func testOldIdIsDeletedWhenReplacedBySecret() throws {
        let context = try makeContext()
        let clip = text("just a note")
        context.insert(clip)
        try context.save()
        let oldID = clip.id
        collect(context)
        XCTAssertTrue(clip.saveEdit(FakeSecret.stripe, in: context, protects: true))
        let secret = try XCTUnwrap(try context.fetch(FetchDescriptor<ClipboardItem>()).first)
        XCTAssertNotEqual(secret.id, oldID)
        XCTAssertEqual(deleted, [oldID])
        XCTAssertEqual(saved, [secret.id])
        let out = SpotlightPlan.changes(saved: [SpotlightPlan.Input(secret, linkPreviews: true)], deleted: Array(deleted))
        XCTAssertEqual(out.upsert, [])
        XCTAssertEqual(Set(out.delete), [oldID, secret.id])
    }

    /// The iPhone's account change or deleted zone: `RemoteApplier.deleteAll`, then a main-context save. Every clip
    /// leaves the index (the indexer also clears the whole domain).
    func testMirrorWipeRemovesEveryClip() throws {
        let context = try makeContext()
        let clips = [text("one"), text("two"), text("https://copyd.app", type: .url)]
        clips.forEach(context.insert)
        try context.save()
        collect(context)
        _ = RemoteApplier.deleteAll(in: context)
        try context.save()
        XCTAssertEqual(deleted, Set(clips.map(\.id)))
        XCTAssertEqual(saved, [])
        XCTAssertEqual(Set(SpotlightPlan.changes(saved: [], deleted: Array(deleted)).delete), Set(clips.map(\.id)))
    }

    /// A delete from another device, the Mac's history-limit clean-up included, lands through `RemoteApplier` on the
    /// main context.
    func testRemoteDeleteLeavesTheIndex() throws {
        let context = try makeContext()
        let gone = text("deleted on the Mac"), kept = text("kept")
        [gone, kept].forEach(context.insert)
        try context.save()
        collect(context)
        _ = RemoteApplier(context: context) { _ in false }
            .apply(clips: [], pinboards: [], entries: [], deletions: [gone.id], systemFields: [:])
        try context.save()
        XCTAssertEqual(deleted, [gone.id])
        XCTAssertEqual(saved, [])
    }

    /// Nothing is handed over before the save lands, and each save hands over only its own changes.
    func testIdsArriveOncePerSave() throws {
        let context = try makeContext()
        collect(context)
        let clip = text("first")
        context.insert(clip)
        XCTAssertEqual(saved, [], "not saved yet")
        try context.save()
        XCTAssertEqual(saved, [clip.id])
        saved = []
        clip.isPinned = true
        try context.save()
        XCTAssertEqual(saved, [clip.id], "an update")
        saved = []
        try context.save()
        XCTAssertEqual(saved, [], "an empty save hands over nothing")
    }

    /// The type and topic passes save through `ignoring`: what they store never shows in Spotlight, so their saves never
    /// reindex. Another clip in the same save still goes, and so does a delete.
    func testIgnoredSavesAreNotHandedOver() throws {
        let context = try makeContext()
        let sorted = text("sorted"), edited = text("edited"), gone = text("gone")
        [sorted, edited, gone].forEach(context.insert)
        try context.save()
        collect(context)
        sorted.smartKinds = 1
        edited.isPinned = true
        try observer?.ignoring([sorted.id, gone.id]) {
            context.delete(gone)
            try context.save()
        }
        XCTAssertEqual(saved, [edited.id])
        XCTAssertEqual(deleted, [gone.id], "a delete is never ignored")
        saved = []
        sorted.isPinned = true
        try context.save()
        XCTAssertEqual(saved, [sorted.id], "only the saves inside `ignoring`")
    }

    // MARK: The indexer's bookkeeping

    func testSameRecordIndexesOnce() {
        let records = SpotlightPlan.IndexedRecords()
        let a = SpotlightRecord(id: UUID(), title: "a", summary: "", thumbnailSource: .none)
        XCTAssertEqual(records.changed([a]), [a], "never indexed")
        records.stored([a])
        XCTAssertEqual(records.changed([a]), [], "saved again, unchanged: a pin, sync bookkeeping")
        let renamed = SpotlightRecord(id: a.id, title: "b", summary: "", thumbnailSource: .none)
        XCTAssertEqual(records.changed([renamed]), [renamed])
        records.removed([a.id])
        XCTAssertEqual(records.changed([a]), [a], "deleted, then back")
        records.stored([a])
        records.removeAll()
        XCTAssertEqual(records.changed([a]), [a], "a rebuild or a clear forgets everything")
    }

    /// The version is stored only once the queue drains with every job done, so a kill mid-queue rebuilds next launch.
    func testVersionIsStoredOnlyOnceTheQueueDrains() {
        var ledger = SpotlightPlan.JobLedger()
        XCTAssertTrue(ledger.start(), "the first job clears the stored version")
        XCTAssertFalse(ledger.start(), "already cleared")
        XCTAssertFalse(ledger.finish(succeeded: true, resets: false), "one still running")
        XCTAssertTrue(ledger.finish(succeeded: true, resets: false), "drained in step")
    }

    func testLostJobKeepsTheVersionClearedUntilARebuild() {
        var ledger = SpotlightPlan.JobLedger()
        _ = ledger.start()
        XCTAssertFalse(ledger.finish(succeeded: false, resets: false), "a lost update")
        _ = ledger.start()
        XCTAssertFalse(ledger.finish(succeeded: true, resets: false), "a later update does not bring it back in step")
        _ = ledger.start()
        XCTAssertTrue(ledger.finish(succeeded: true, resets: true), "a rebuild does")
        _ = ledger.start()
        XCTAssertFalse(ledger.finish(succeeded: false, resets: true), "a failed rebuild does not")
    }

    // MARK: Reading a clip

    func testInputFromClip() throws {
        let files = [FileManifestEntry(name: "Report.pdf", size: 3, uti: "com.adobe.pdf")]
        let bundle = ClipboardItem(contentType: .files, rawData: Data(), contentHash: "f")
        bundle.fileManifestData = try JSONEncoder().encode(files)
        XCTAssertEqual(SpotlightPlan.Input(bundle, linkPreviews: true).fileNames, ["Report.pdf"])

        let link = text("https://copyd.app", type: .url)
        link.linkTitle = "Copyd"
        link.linkImageData = Data([1])
        let on = SpotlightPlan.Input(link, linkPreviews: true)
        XCTAssertEqual(on.linkTitle, "Copyd")
        XCTAssertTrue(on.hasThumbnail, "a link's thumbnail is its page image")
        let off = SpotlightPlan.Input(link, linkPreviews: false)
        XCTAssertNil(off.linkTitle, "with link previews off, Spotlight shows the URL like the cards do")
        XCTAssertFalse(off.hasThumbnail)

        let long = text(String(repeating: "x", count: 100_000))
        XCTAssertEqual(SpotlightPlan.Input(long, linkPreviews: true).text?.count, SpotlightPlan.textPrefix)
        let secret = text(FakeSecret.stripe)
        secret.isSensitive = true
        XCTAssertTrue(SpotlightPlan.Input(secret, linkPreviews: true).isSensitive)
    }
}
