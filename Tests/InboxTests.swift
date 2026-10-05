import AppKit
import SwiftData
import XCTest

@MainActor
final class InboxTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        let group = FileManager.default.temporaryDirectory.appendingPathComponent("InboxTests-\(UUID().uuidString)")
        dir = Inbox.directory(groupContainer: group)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func items() throws -> [ClipboardItem] {
        try context.fetch(FetchDescriptor<ClipboardItem>(sortBy: [SortDescriptor(\.copiedAt)]))
    }

    private func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func png() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.yellow.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 400).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func testWriteThenDrainImportsText() throws {
        let at = now.addingTimeInterval(-60)
        try Inbox.write(InboxItem(kind: .text, text: "https://copyd.app/x", createdAt: at), payload: nil, in: dir)
        XCTAssertEqual(try files().filter { $0.hasSuffix(".json") }.count, 1)
        XCTAssertEqual(try files().filter { $0.hasSuffix(".tmp") }, [], "no temp file left behind")

        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 1)
        XCTAssertFalse(context.hasChanges, "saved, not left for autosave")
        let item = try XCTUnwrap(try items().first)
        XCTAssertEqual(item.contentType, .url)
        XCTAssertEqual(item.textContent, "https://copyd.app/x")
        XCTAssertEqual(item.rawData, Data("https://copyd.app/x".utf8))
        XCTAssertEqual(item.contentHash, ClipCapture.hash(Data("https://copyd.app/x".utf8)))
        XCTAssertEqual(item.copiedAt, at)
        XCTAssertEqual(item.sourceAppName, "Share")
    }

    func testDrainImportsImageWithThumbnail() throws {
        let png = png()
        try Inbox.write(InboxItem(kind: .image, createdAt: now, source: "Photos"), payload: png, in: dir)
        XCTAssertEqual(try files().count, 2, "the JSON and its payload")

        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 1)
        let item = try XCTUnwrap(try items().first)
        XCTAssertEqual(item.contentType, .image)
        XCTAssertEqual(item.rawData, png)
        XCTAssertNil(item.textContent)
        XCTAssertEqual(item.contentHash, ClipCapture.hash(png))
        XCTAssertEqual(item.sourceAppName, "Photos")
        let thumbnail = try XCTUnwrap(item.thumbnailData)
        XCTAssertEqual(NSImage(data: thumbnail)?.size, NSSize(width: 320, height: 160))
        XCTAssertEqual(try files(), [], "payload deleted too")
    }

    func testDrainImportsOnceAndDeletesFiles() throws {
        try Inbox.write(InboxItem(kind: .text, text: "a", createdAt: now), payload: nil, in: dir)
        try Inbox.write(InboxItem(kind: .image, createdAt: now), payload: png(), in: dir)

        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 2)
        XCTAssertEqual(try files(), [])
        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 0, "a second drain finds nothing")
        XCTAssertEqual(try items().count, 2)
    }

    func testCorruptFileIsSkippedAndRemoved() throws {
        let id = UUID().uuidString
        try Data("{\"id\":".utf8).write(to: dir.appendingPathComponent("\(id).json"))
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("\(id).payload"))
        try Inbox.write(InboxItem(kind: .text, text: "good", createdAt: now), payload: nil, in: dir)
        // An image whose payload never made it: nothing to import, but the JSON must not linger.
        try JSONEncoder().encode(InboxItem(kind: .image, payloadFile: "missing.payload", createdAt: now))
            .write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))

        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 1)
        XCTAssertEqual(try items().map(\.textContent), ["good"])
        XCTAssertEqual(try files(), [])
    }

    func testDuplicateWithin10sSkipped() throws {
        let existing = ClipboardItem(contentType: .plainText, rawData: Data("x".utf8), textContent: "x",
                                     contentHash: ClipCapture.hash(Data("x".utf8)))
        existing.copiedAt = now.addingTimeInterval(-30)
        context.insert(existing)
        try context.save()
        // 5 s after the existing copy: a duplicate. 20 s after: a new clip.
        try Inbox.write(InboxItem(kind: .text, text: "x", createdAt: now.addingTimeInterval(-25)), payload: nil, in: dir)
        try Inbox.write(InboxItem(kind: .text, text: "x", createdAt: now.addingTimeInterval(-10)), payload: nil, in: dir)

        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 1)
        XCTAssertEqual(try items().map(\.copiedAt), [now.addingTimeInterval(-30), now.addingTimeInterval(-10)])
        XCTAssertEqual(try files(), [], "the skipped duplicate is deleted too")
    }

    func testDrainSkipsAutoItemAlreadyInHistory() throws {
        let existing = ClipboardItem(contentType: .plainText, rawData: Data("x".utf8), textContent: "x",
                                     contentHash: ClipCapture.hash(Data("x".utf8)))
        existing.copiedAt = now.addingTimeInterval(-3600)  // far outside the 10 s rule
        context.insert(existing)
        try context.save()
        try Inbox.write(InboxItem(kind: .text, text: "x", createdAt: now, source: "iPhone", auto: true), payload: nil, in: dir)
        try Inbox.write(InboxItem(kind: .text, text: "new", createdAt: now, source: "iPhone", auto: true), payload: nil, in: dir)

        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 1)
        XCTAssertEqual(try items().map(\.textContent), ["x", "new"])
        XCTAssertEqual(try items().last?.sourceAppName, "iPhone")
        XCTAssertEqual(try files(), [], "the skipped item is deleted too")
    }

    func testDrainKeepsExplicitShareRuleFor10s() throws {
        let existing = ClipboardItem(contentType: .plainText, rawData: Data("x".utf8), textContent: "x",
                                     contentHash: ClipCapture.hash(Data("x".utf8)))
        existing.copiedAt = now.addingTimeInterval(-3600)
        context.insert(existing)
        try context.save()
        // A Share is explicit: content already in history is saved again, as on the Mac, unless it is 10 s old or less.
        try Inbox.write(InboxItem(kind: .text, text: "x", createdAt: now, auto: false), payload: nil, in: dir)
        try Inbox.write(InboxItem(kind: .text, text: "x", createdAt: now.addingTimeInterval(5), auto: false), payload: nil, in: dir)

        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now.addingTimeInterval(5)), 1)
        XCTAssertEqual(try items().map(\.copiedAt), [now.addingTimeInterval(-3600), now])
    }

    func testOldInboxJSONWithoutAutoDecodes() throws {
        // An item written by the Share extension before `auto` existed.
        let json = #"{"id":"9D3B1E36-6C64-4C55-8E0B-5F6C0B9A1E01","kind":"text","text":"old share","createdAt":720000000}"#
        let item = try JSONDecoder().decode(InboxItem.self, from: Data(json.utf8))
        XCTAssertFalse(item.auto)
        XCTAssertEqual(item.text, "old share")

        try Data(json.utf8).write(to: dir.appendingPathComponent("\(item.id).json"))
        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 1)
        XCTAssertEqual(try items().map(\.textContent), ["old share"])
    }

    func testDrainOrderIsCreatedAt() throws {
        // Same text 5 s apart, so only the first one processed survives the duplicate rule.
        // Written newest first, with ids that sort newest first, so neither write nor name order hides a bug.
        let early = now.addingTimeInterval(-20), late = now.addingTimeInterval(-15)
        try Inbox.write(InboxItem(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                                  kind: .text, text: "same", createdAt: late), payload: nil, in: dir)
        try Inbox.write(InboxItem(id: UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000001")!,
                                  kind: .text, text: "same", createdAt: early), payload: nil, in: dir)

        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 1)
        XCTAssertEqual(try items().map(\.copiedAt), [early])
    }

    func testFutureCreatedAtIsClampedToNow() throws {
        try Inbox.write(InboxItem(kind: .text, text: "later", createdAt: now.addingTimeInterval(3600)), payload: nil, in: dir)
        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 1)
        XCTAssertEqual(try items().first?.copiedAt, now, "a clip is never dated in the future")
    }

    func testSweepsOldOrphansOnly() throws {
        let oldPayload = dir.appendingPathComponent("\(UUID()).payload")
        let freshTmp = dir.appendingPathComponent("\(UUID()).json.tmp")
        try Data([1]).write(to: oldPayload)
        try Data([2]).write(to: freshTmp)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: oldPayload.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: freshTmp.path)

        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 0)
        XCTAssertEqual(try files(), [freshTmp.lastPathComponent], "only the stale orphan goes")
    }

    func testFailedSaveKeepsFiles() throws {
        // A read-only store rejects every save.
        let url = dir.deletingLastPathComponent().appendingPathComponent("ro.store")
        let types: [any PersistentModel.Type] = [ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self]
        _ = try ModelContainer(for: Schema(types), configurations: ModelConfiguration(url: url))
        let disk = try ModelContainer(for: Schema(types), configurations: ModelConfiguration(url: url, allowsSave: false))
        let ctx = disk.mainContext
        try Inbox.write(InboxItem(kind: .text, text: "keep me", createdAt: now), payload: nil, in: dir)

        XCTAssertEqual(Inbox.drain(in: ctx, directory: dir, now: now), 0)
        XCTAssertEqual(try files().count, 1, "kept for the next drain")
        XCTAssertFalse(ctx.hasChanges, "rolled back, not left pending")
    }

    /// Share and the keyboard's auto-capture both land here, so both mark a secret.
    func testDrainMarksSecretsSensitive() throws {
        try Inbox.write(InboxItem(kind: .text, text: FakeSecret.jwt, createdAt: now.addingTimeInterval(-2), auto: true),
                        payload: nil, in: dir)
        try Inbox.write(InboxItem(kind: .text, text: "plain", createdAt: now.addingTimeInterval(-1)), payload: nil, in: dir)
        XCTAssertEqual(Inbox.drain(in: context, directory: dir, now: now), 2)
        XCTAssertEqual(try items().map(\.isSensitive), [true, false])
    }
}
