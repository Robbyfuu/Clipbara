import SwiftData
import XCTest

/// `ClipboardItem` as it was before `fromUniversalClipboard`, the shape of every store on disk today.
private enum V1 {
    @Model final class ClipboardItem {
        var id: UUID
        var contentTypeRaw: String
        @Attribute(.externalStorage) var rawData: Data
        var textContent: String?
        @Attribute(.externalStorage) var thumbnailData: Data?
        var sourceAppName: String?
        var sourceAppBundleId: String?
        var contentHash: String
        var copiedAt: Date
        var userTitle: String?
        var isPinned: Bool
        var syncSystemFields: Data?
        var fileManifestData: Data?

        init(id: UUID) {
            self.id = id
            contentTypeRaw = "plainText"
            rawData = Data("kept".utf8)
            textContent = "kept"
            contentHash = "h"
            copiedAt = Date(timeIntervalSince1970: 1_700_000_000)
            isPinned = true
        }
    }
}

@MainActor
final class StoreMigrationTests: XCTestCase {
    /// The Mac's store holds history found nowhere else, so the new attribute must open an existing store in place.
    func testExistingStoreGainsTheUniversalClipboardFlag() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Test.store")
        let id = UUID()
        do {
            let old = try ModelContainer(for: Schema([V1.ClipboardItem.self]),
                                         configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
            old.mainContext.insert(V1.ClipboardItem(id: id))
            try old.mainContext.save()
        }
        let schema = Schema([ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self])
        let new = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        let clip = try XCTUnwrap(try new.mainContext.fetch(FetchDescriptor<ClipboardItem>()).first)
        XCTAssertEqual(clip.id, id)
        XCTAssertEqual(clip.textContent, "kept")
        XCTAssertTrue(clip.isPinned)
        XCTAssertFalse(clip.fromUniversalClipboard)
        XCTAssertFalse(clip.isSensitive, "existing clips are not secrets: detection runs only on new copies")
        XCTAssertNil(clip.ocrText)
        XCTAssertFalse(clip.ocrDone, "existing images are read by the first fill pass")
        XCTAssertNil(clip.linkTitle)
        XCTAssertNil(clip.linkImageData)
        XCTAssertFalse(clip.linkPreviewDone, "existing links are fetched by the first fill pass")
        // The stored values, not just the model's defaults: the sweep, the uploads and the OCR fill all fetch by them.
        let unflagged = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.isSensitive == false && $0.ocrDone == false })
        XCTAssertEqual(try new.mainContext.fetchCount(unflagged), 1)
        let unfetched = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.linkPreviewDone == false && $0.linkTitle == nil })
        XCTAssertEqual(try new.mainContext.fetchCount(unfetched), 1)
        XCTAssertEqual(clip.smartKinds, 0)
        XCTAssertEqual(clip.smartKindsVersion, 0, "existing clips are sorted by the first fill pass")
        let unsorted = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.smartKinds == 0 && $0.smartKindsVersion < 1 })
        XCTAssertEqual(try new.mainContext.fetchCount(unsorted), 1)
        XCTAssertNil(clip.topicRaw)
        XCTAssertFalse(clip.topicDone, "existing clips are asked about by the first fill pass")
        let unasked = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.topicDone == false && $0.topicRaw == nil })
        XCTAssertEqual(try new.mainContext.fetchCount(unasked), 1)
    }

    /// Paste history is a new Mac-only entity: today's store must open in place with it, keeping every clip.
    func testExistingStoreGainsPasteHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Test.store")
        let id: UUID
        do {
            let schema = Schema([ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self])
            let old = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
            let clip = ClipboardItem(contentType: .plainText, rawData: Data("kept".utf8), textContent: "kept", contentHash: "h")
            id = clip.id
            old.mainContext.insert(clip)
            try old.mainContext.save()
        }
        let schema = Schema([ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self, PasteEvent.self])
        let new = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        XCTAssertEqual(try new.mainContext.fetch(FetchDescriptor<ClipboardItem>()).map(\.id), [id])
        PasteEvent.record([id], app: "com.apple.Safari", in: new.mainContext)
        XCTAssertEqual(try new.mainContext.fetchCount(FetchDescriptor<PasteEvent>()), 1)
    }

    /// App identities are a new synced entity: the Mac's store, paste history included, opens in place with it.
    func testMacStoreGainsAppIdentities() throws {
        let url = try storeURL()
        let id = try seedStore(at: url, models: [ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self, PasteEvent.self])
        let schema = Schema(StoreSchema.mac)
        let new = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        XCTAssertEqual(try new.mainContext.fetch(FetchDescriptor<ClipboardItem>()).map(\.id), [id])
        XCTAssertEqual(try new.mainContext.fetchCount(FetchDescriptor<AppIdentity>()), 0)
        new.mainContext.insert(AppIdentity(bundleId: "com.apple.Safari", name: "Safari", iconPNG: Data([1]), colorHex: "#1E90FF"))
        try new.mainContext.save()
        XCTAssertEqual(try new.mainContext.fetch(FetchDescriptor<AppIdentity>()).map(\.bundleId), ["com.apple.Safari"])
    }

    /// The iPhone's store migrates when the app opens it; the keyboard and the widget then open it read-only with the
    /// same shared schema and read the identities.
    func testPhoneStoreGainsAppIdentitiesAndOpensReadOnly() throws {
        let url = try storeURL()
        let id = try seedStore(at: url, models: [ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self])
        let schema = Schema(StoreSchema.models)
        do {
            let app = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
            app.mainContext.insert(AppIdentity(bundleId: "com.apple.Safari", name: "Safari", iconPNG: Data([1]), colorHex: "#1E90FF"))
            try app.mainContext.save()
        }
        let keyboard = try ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none))
        let context = ModelContext(keyboard)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ClipboardItem>()).map(\.id), [id])
        XCTAssertEqual(try context.fetch(FetchDescriptor<AppIdentity>()).map(\.bundleId), ["com.apple.Safari"])
    }

    /// Why the keyboard and the widget say "Open Copyd": until the app migrates the store, their read-only open of it
    /// with the new schema fails.
    func testReadOnlyOpenOfAnUnmigratedStoreFails() throws {
        let url = try storeURL()
        _ = try seedStore(at: url, models: [ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self])
        let schema = Schema(StoreSchema.models)
        XCTAssertThrowsError(try ModelContainer(for: schema, configurations: ModelConfiguration(
            schema: schema, url: url, allowsSave: false, cloudKitDatabase: .none)))
    }

    private func storeURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("Test.store")
    }

    /// A store of today's shape (`models`), holding one clip. Returns the clip's id.
    private func seedStore(at url: URL, models: [any PersistentModel.Type]) throws -> UUID {
        let schema = Schema(models)
        let old = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        let clip = ClipboardItem(contentType: .plainText, rawData: Data("kept".utf8), textContent: "kept", contentHash: "h")
        old.mainContext.insert(clip)
        try old.mainContext.save()
        return clip.id
    }
}
