import CoreText
import ImageIO
import SwiftData
import UniformTypeIdentifiers
import XCTest

/// Review focus 5: OCR reads a bounded image, one small batch at a time, newest first.
final class OCRPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func clip(_ minutesAgo: Int, image: Bool = true, done: Bool = false)
        -> (id: UUID, isImage: Bool, ocrDone: Bool, copiedAt: Date) {
        (UUID(), image, done, now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    }

    func testBatchIsTheNewestImagesNotYetRead() {
        let text = clip(0, image: false), a = clip(1), done = clip(2, done: true), b = clip(3), c = clip(4)
        XCTAssertEqual(OCRPlan.nextBatch(clips: [c, done, text, b, a], limit: 2), [a.id, b.id])
    }

    func testBatchHoldsTenByDefault() {
        let clips = (0..<25).map { clip($0) }
        XCTAssertEqual(OCRPlan.nextBatch(clips: clips.shuffled()), clips.prefix(10).map(\.id))
    }

    func testDoneClipsAreNeverReadAgain() {
        XCTAssertEqual(OCRPlan.nextBatch(clips: (0..<5).map { clip($0, done: true) }), [])
    }

    /// The window counts image clips only: newer text clips never push an image out of it.
    func testWindowCoversTheNewest300Images() {
        let texts = (0..<50).map { clip($0, image: false) }
        let read = (50..<349).map { clip($0, done: true) }
        let last = clip(349), outside = clip(350)
        XCTAssertEqual(OCRPlan.nextBatch(clips: texts + read + [last, outside]), [last.id])
        XCTAssertEqual(OCRPlan.nextBatch(clips: read + [last, outside], window: 299), [])
    }

    func testTargetIs2048Pixels() {
        XCTAssertEqual(OCRPlan.targetPixelSize, 2048)
    }

    func testDownsampleFitsTheLongestSideIn2048() throws {
        let wide = try XCTUnwrap(OCRPlan.downsampled(OCRImage.png(width: 5000, height: 2500)))
        XCTAssertEqual([wide.width, wide.height], [2048, 1024])
        let tall = try XCTUnwrap(OCRPlan.downsampled(OCRImage.png(width: 1000, height: 4096)))
        XCTAssertEqual(tall.height, 2048)
        XCTAssertEqual(tall.width, 500)
    }

    func testDownsampleNeverUpscales() throws {
        let small = try XCTUnwrap(OCRPlan.downsampled(OCRImage.png(width: 800, height: 400)))
        XCTAssertEqual([small.width, small.height], [800, 400])
    }

    func testDownsampleOfNonImageDataIsNil() {
        XCTAssertNil(OCRPlan.downsampled(Data("not an image".utf8)))
    }

    @MainActor
    func testRecognizedTextIsAnImagesNonEmptyText() throws {
        let container = try ModelContainer(for: ClipboardItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let image = ClipboardItem(contentType: .image, rawData: Data(), contentHash: "i")
        let text = ClipboardItem(contentType: .plainText, rawData: Data(), textContent: "t", contentHash: "t")
        [image, text].forEach(container.mainContext.insert)
        XCTAssertNil(image.recognizedText, "not read yet")
        image.ocrText = ""
        XCTAssertNil(image.recognizedText, "read, no text")
        image.ocrText = "Copyd OCR test"
        XCTAssertEqual(image.recognizedText, "Copyd OCR test")
        text.ocrText = "stray"
        XCTAssertNil(text.recognizedText, "only images carry recognized text")
    }

    func testRecognizerReadsTheTextInAnImage() throws {
        guard case .text(let text?) = ImageTextRecognizer.text(in: OCRImage.png(text: "Copyd OCR test")) else {
            return XCTFail("no text")
        }
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Copyd OCR test"), text)
    }

    /// No text, or data that is not an image, is a finished read: never retried.
    func testRecognizerFindsNoTextInABlankImage() {
        XCTAssertEqual(ImageTextRecognizer.text(in: OCRImage.png(width: 600, height: 300)), .text(nil))
        XCTAssertEqual(ImageTextRecognizer.text(in: Data("not an image".utf8)), .text(nil))
    }
}

@MainActor
final class ImageTextQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var saves: [Set<UUID>] = []
    private var titleWasSaved: Bool?

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        saves = []
    }

    private func insert(_ type: ContentType, _ data: Data, text: String? = nil) throws -> ClipboardItem {
        let item = ClipboardItem(contentType: type, rawData: data, textContent: text, contentHash: UUID().uuidString)
        container.mainContext.insert(item)
        try container.mainContext.save()
        return item
    }

    private func makeQueue(recognize: (@Sendable (Data) -> ImageTextRecognizer.Outcome)? = nil) -> ImageTextQueue {
        let save: @MainActor (Set<UUID>) -> Void = { [unowned self] ids in
            saves.append(ids)
            try? container.mainContext.save()
        }
        guard let recognize else { return ImageTextQueue(container: container, save: save) }
        return ImageTextQueue(container: container, recognize: recognize, save: save)
    }

    /// Waits for the pass and any pass a `fill` queued behind it.
    private func finish(_ queue: ImageTextQueue) async {
        while let task = queue.task { await task.value }
    }

    func testFillReadsNewImagesAndMarksEachOneDone() async throws {
        let withText = try insert(.image, OCRImage.png(text: "Copyd OCR test"))
        let blank = try insert(.image, OCRImage.png(width: 600, height: 300))
        let text = try insert(.plainText, Data("x".utf8), text: "x")
        let queue = makeQueue()
        queue.fill()
        await queue.task?.value
        XCTAssertTrue(withText.ocrText?.localizedCaseInsensitiveContains("Copyd OCR test") == true, withText.ocrText ?? "nil")
        XCTAssertTrue(withText.ocrDone)
        XCTAssertNil(blank.ocrText)
        XCTAssertTrue(blank.ocrDone, "an image with no text is never read again")
        XCTAssertFalse(text.ocrDone)
        XCTAssertEqual(saves, [[withText.id, blank.id]], "one batch, saved through the local-only save")
    }

    func testFillWhileAPassRunsNeverStartsASecond() async throws {
        _ = try insert(.image, OCRImage.png(text: "Copyd OCR test"))
        let queue = makeQueue()
        queue.fill()
        let first = queue.task
        queue.fill()
        XCTAssertNotNil(first)
        XCTAssertEqual(queue.task, first)
        await queue.task?.value
        XCTAssertEqual(saves.count, 1)
    }

    /// A Vision error is not a read: the clip stays unread for the next `fill`, and the pass never reads it again,
    /// even across batches.
    func testFailedReadIsRetriedByTheNextFillOnly() async throws {
        let failing = Data([0])
        let others = try (1...11).map { try insert(.image, Data([UInt8($0)])) }
        let image = try insert(.image, failing)
        let reads = Reads()
        let broken = makeQueue { data in
            reads.add(data)
            return data == failing ? .failed : .text("ok")
        }
        broken.fill()
        await finish(broken)
        XCTAssertFalse(image.ocrDone)
        XCTAssertNil(image.ocrText)
        XCTAssertEqual(reads.count(of: failing), 1, "once per pass, not once per batch")
        XCTAssertTrue(others.allSatisfy(\.ocrDone))

        let fixed = makeQueue { _ in .text("Copyd OCR test") }
        fixed.fill()
        await finish(fixed)
        XCTAssertTrue(image.ocrDone)
        XCTAssertEqual(image.ocrText, "Copyd OCR test")
    }

    func testEmptyReadIsDone() async throws {
        let image = try insert(.image, Data([1]))
        let queue = makeQueue { _ in .text(nil) }
        queue.fill()
        await finish(queue)
        XCTAssertTrue(image.ocrDone)
        XCTAssertNil(image.ocrText)
    }

    /// A user change still pending on the main context is saved first, by a save the sync tracker reports.
    func testPendingChangesAreSavedBeforeTheLocalOnlySave() async throws {
        let image = try insert(.image, Data([1]))
        let note = try insert(.plainText, Data("n".utf8), text: "n")
        let id = note.id
        let queue = ImageTextQueue(container: container, recognize: { _ in .text("t") }) { [unowned self] _ in
            let fresh = try? ModelContext(container).fetch(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })).first
            titleWasSaved = fresh?.userTitle == "renamed"
            try? container.mainContext.save()
        }
        queue.fill()
        note.userTitle = "renamed"  // unsaved when the pass writes
        await finish(queue)
        XCTAssertTrue(image.ocrDone)
        XCTAssertEqual(titleWasSaved, true)
    }

    func testStopMidPassKeepsWhatItReadAndReadsNoMore() async throws {
        let older = try insert(.image, Data([1]))
        let newer = try insert(.image, Data([2]))
        let gate = Gate()
        let queue = makeQueue { data in gate.enter(); return .text("t\(data[0])") }
        queue.fill()
        await gate.waitUntilEntered()
        queue.stop()
        gate.open()
        await finish(queue)
        XCTAssertTrue(newer.ocrDone, "the image being read is kept")
        XCTAssertFalse(older.ocrDone)
        XCTAssertEqual(gate.entries, 1)
    }

    /// `fill` right after `stop`, while the stopped pass still reads its image, restarts once that image is done.
    func testFillAfterStopMidPassRestartsAndCompletes() async throws {
        let older = try insert(.image, Data([1]))
        let newer = try insert(.image, Data([2]))
        let gate = Gate()
        let queue = makeQueue { data in gate.enter(); return .text("t\(data[0])") }
        queue.fill()
        await gate.waitUntilEntered()
        queue.stop()
        queue.fill()
        gate.open()
        await finish(queue)
        XCTAssertEqual(newer.ocrText, "t2")
        XCTAssertEqual(older.ocrText, "t1")
        XCTAssertEqual(gate.entries, 2, "each image read once")
    }
}

/// The recognizer's inputs, from any thread.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [Data] = []
    func add(_ data: Data) { lock.withLock { all.append(data) } }
    func count(of data: Data) -> Int { lock.withLock { all.filter { $0 == data }.count } }
}

/// Holds the recognizer inside its first read until `open`, so a test can stop the pass mid-read.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var count = 0
    private var isOpen = false

    var entries: Int { lock.withLock { count } }

    func enter() {
        let wait = lock.withLock { count += 1; return !isOpen }
        if wait { released.wait() }
    }

    func open() {
        lock.withLock { isOpen = true }
        released.signal()
    }

    func waitUntilEntered() async {
        while entries == 0 { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// White PNGs, with optional black text, for the recognizer.
enum OCRImage {
    static func png(text: String = "", width: Int = 1200, height: Int = 300) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !text.isEmpty {
            let font = CTFontCreateWithName("Helvetica" as CFString, 72, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            context.textPosition = CGPoint(x: 40, y: height / 2 - 24)
            CTLineDraw(line, context)
        }
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}
