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
        let text = try XCTUnwrap(ImageTextRecognizer.text(in: OCRImage.png(text: "Copyd OCR test")))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Copyd OCR test"), text)
    }

    func testRecognizerFindsNoTextInABlankImage() {
        XCTAssertNil(ImageTextRecognizer.text(in: OCRImage.png(width: 600, height: 300)))
        XCTAssertNil(ImageTextRecognizer.text(in: Data("not an image".utf8)))
    }
}

@MainActor
final class ImageTextQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var saves: [Set<UUID>] = []

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

    private func makeQueue() -> ImageTextQueue {
        ImageTextQueue(container: container) { [unowned self] ids in
            saves.append(ids)
            try? container.mainContext.save()
        }
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

    func testStopEndsThePass() async throws {
        let image = try insert(.image, OCRImage.png(text: "Copyd OCR test"))
        let queue = makeQueue()
        queue.fill()
        queue.stop()
        await queue.task?.value
        XCTAssertFalse(image.ocrDone)
        XCTAssertEqual(saves, [])
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
