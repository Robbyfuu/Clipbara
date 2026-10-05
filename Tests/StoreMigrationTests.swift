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
}
