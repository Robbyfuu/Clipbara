import SwiftData
import XCTest

/// The MCP tools against an in-memory store (spec §3): secrets never leave it, the search fields, filters and caps.
@MainActor
final class StoreClipLibraryTests: XCTestCase {
    private var container: ModelContainer!
    private var library: StoreClipLibrary!

    override func setUp() async throws {
        let schema = Schema(StoreSchema.models)
        container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        library = StoreClipLibrary(container: container, smartBoards: { SmartBoard.allCases }) { _ in }
    }

    @discardableResult
    private func insert(_ type: ContentType, _ text: String?, dt: TimeInterval = 0, app: String? = nil,
                        secret: Bool = false, _ configure: (ClipboardItem) -> Void = { _ in }) throws -> ClipboardItem {
        let item = ClipboardItem(contentType: type, rawData: Data((text ?? "").utf8), textContent: text, sourceAppName: app,
                                 contentHash: UUID().uuidString)
        item.copiedAt = Date(timeIntervalSince1970: 1_800_000_000 + dt)
        item.isSensitive = secret
        configure(item)
        container.mainContext.insert(item)
        try container.mainContext.save()
        return item
    }

    @discardableResult
    private func pinboard(_ name: String, order: Int = 0, _ clips: [ClipboardItem]) throws -> Pinboard {
        let board = Pinboard(name: name, displayOrder: order)
        container.mainContext.insert(board)
        for (index, clip) in clips.enumerated() {
            container.mainContext.insert(PinboardEntry(clipboardItem: clip, pinboard: board, displayOrder: index))
        }
        try container.mainContext.save()
        return board
    }

    private func ids(query: String? = nil, type: ClipKind? = nil, board: String? = nil, limit: Int = 50) async throws -> [UUID] {
        try await library.search(query: query, type: type, board: board, limit: limit).map(\.id)
    }

    // MARK: secrets

    func testSecretsAreInvisible() async throws {
        let visible = try insert(.plainText, "the visible token", dt: 1)
        let secret = try insert(.plainText, "sk-live-the secret token", dt: 2, secret: true) {
            $0.isPinned = true
            $0.smartKinds = SmartBoard.code.bit
            $0.topicRaw = SmartBoard.work.rawValue
        }
        try pinboard("Keys", [secret, visible])

        let all = try await ids()
        XCTAssertEqual(all, [visible.id])
        let byQuery = try await ids(query: "token")
        XCTAssertEqual(byQuery, [visible.id])
        let secretQuery = try await ids(query: "sk-live")
        XCTAssertEqual(secretQuery, [])
        let onPinboard = try await ids(board: "Keys")
        XCTAssertEqual(onPinboard, [visible.id])
        let onCode = try await ids(board: "code")
        XCTAssertEqual(onCode, [])
        let onWork = try await ids(board: "work")
        XCTAssertEqual(onWork, [])
        let asCode = try await ids(type: .code)
        XCTAssertEqual(asCode, [])

        let detail = try await library.clip(id: secret.id)
        XCTAssertNil(detail, "a secret by id is not found")

        let boards = try await library.boards()
        XCTAssertEqual(boards, [BoardSummary(id: nil, name: "Keys", count: 1)],
                       "the pinboard counts the visible clip only, and no smart board shows for the secret alone")
    }

    /// With "Protect secrets" off nothing is flagged, yet a key never leaves Copyd: the text is checked itself, as
    /// Spotlight does.
    func testTextThatReadsAsASecretIsInvisibleWithProtectionOff() async throws {
        let visible = try insert(.plainText, "plain words", dt: 1)
        let key = try insert(.plainText, FakeSecret.stripe, dt: 2) {
            $0.smartKinds = SmartBoard.code.bit
            $0.topicRaw = SmartBoard.work.rawValue
        }
        try pinboard("Keys", [key, visible])

        let all = try await ids()
        XCTAssertEqual(all, [visible.id])
        let byQuery = try await ids(query: "sk_live")
        XCTAssertEqual(byQuery, [])
        let onPinboard = try await ids(board: "Keys")
        XCTAssertEqual(onPinboard, [visible.id])
        let onCode = try await ids(board: "code")
        XCTAssertEqual(onCode, [])
        let detail = try await library.clip(id: key.id)
        XCTAssertNil(detail)

        let boards = try await library.boards()
        XCTAssertEqual(boards, [BoardSummary(id: nil, name: "Keys", count: 1)],
                       "no board counts the key, and no smart board shows for it alone")
    }

    func testAnImageWhoseTextReadsAsASecretIsInvisible() async throws {
        let visible = try insert(.image, nil, dt: 1) {
            $0.ocrText = "Receipt 42"
            $0.smartKinds = SmartBoard.images.bit
        }
        let screenshot = try insert(.image, nil, dt: 2) {
            $0.ocrText = FakeSecret.stripe
            $0.smartKinds = SmartBoard.images.bit
        }
        try pinboard("Shots", [screenshot, visible])

        let all = try await ids()
        XCTAssertEqual(all, [visible.id])
        let images = try await ids(type: .image)
        XCTAssertEqual(images, [visible.id])
        let onBoard = try await ids(board: "images")
        XCTAssertEqual(onBoard, [visible.id])
        let detail = try await library.clip(id: screenshot.id)
        XCTAssertNil(detail)

        let boards = try await library.boards()
        XCTAssertEqual(boards, [BoardSummary(id: nil, name: "Shots", count: 1),
                                BoardSummary(id: SmartBoard.images.rawValue, name: SmartBoard.images.title, count: 1)])
    }

    // MARK: search

    func testSearchMatchesTextOCRLinkTitlesAndFileNamesIgnoringCaseAndAccents() async throws {
        let text = try insert(.plainText, "Reunión con el equipo", dt: 1)
        let image = try insert(.image, nil, dt: 2) { $0.ocrText = "Factura número 42" }
        let link = try insert(.url, "https://example.com/menu", dt: 3) { $0.linkTitle = "Café del Centro" }
        let files = try insert(.files, nil, dt: 4) {
            $0.fileManifestData = try? JSONEncoder().encode([FileManifestEntry(name: "Presupuesto.pdf", size: 10, uti: "com.adobe.pdf")])
        }
        try insert(.plainText, "unrelated", dt: 5, app: "Reunion Notes")

        let byText = try await ids(query: "REUNION")
        XCTAssertEqual(byText, [text.id], "text matches ignoring case and accents; the app name is not searched")
        let byOCR = try await ids(query: "numero")
        XCTAssertEqual(byOCR, [image.id])
        let byTitle = try await ids(query: "cafe")
        XCTAssertEqual(byTitle, [link.id])
        let byFileName = try await ids(query: "presupuesto")
        XCTAssertEqual(byFileName, [files.id])
        let none = try await ids(query: "nothing like this")
        XCTAssertEqual(none, [])
    }

    func testResultsAreNewestFirstWithTheirSummaryFields() async throws {
        let older = try insert(.plainText, "older", dt: 1, app: "Notes")
        let newer = try insert(.url, "https://apple.com", dt: 2, app: "Safari") { $0.isPinned = true }

        let results = try await library.search(query: nil, type: nil, board: nil, limit: 20)

        XCTAssertEqual(results, [
            ClipSummary(id: newer.id, type: .link, preview: "https://apple.com", app: "Safari", copiedAt: newer.copiedAt, pinned: true),
            ClipSummary(id: older.id, type: .text, preview: "older", app: "Notes", copiedAt: older.copiedAt, pinned: false),
        ])
    }

    func testTypeFilter() async throws {
        let text = try insert(.plainText, "hello", dt: 1)
        let rich = try insert(.richText, "rich", dt: 2)
        let code = try insert(.plainText, "let x = 1", dt: 3) { $0.smartKinds = SmartBoard.code.bit }
        let link = try insert(.url, "https://apple.com", dt: 4)
        let image = try insert(.image, nil, dt: 5)
        let files = try insert(.files, "a.pdf", dt: 6)
        let fileURL = try insert(.fileURL, "b.txt", dt: 7)
        let color = try insert(.color, "#FF0000", dt: 8)

        let texts = try await ids(type: .text)
        XCTAssertEqual(texts, [rich.id, text.id], "code is its own type")
        let codes = try await ids(type: .code)
        XCTAssertEqual(codes, [code.id])
        let links = try await ids(type: .link)
        XCTAssertEqual(links, [link.id])
        let images = try await ids(type: .image)
        XCTAssertEqual(images, [image.id])
        let allFiles = try await ids(type: .file)
        XCTAssertEqual(allFiles, [fileURL.id, files.id])
        let colors = try await ids(type: .color)
        XCTAssertEqual(colors, [color.id])
    }

    func testBoardFilterByPinboardNameOrSmartBoardID() async throws {
        let recipe = try insert(.plainText, "pancakes", dt: 1)
        let link = try insert(.url, "https://apple.com", dt: 2) { $0.smartKinds = SmartBoard.links.bit }
        let work = try insert(.plainText, "quarterly report", dt: 3) { $0.topicRaw = SmartBoard.work.rawValue }
        try pinboard("Recetas", [recipe])
        try pinboard("Empty", order: 1, [])

        let byName = try await ids(board: "recetas")
        XCTAssertEqual(byName, [recipe.id], "a pinboard name matches ignoring case")
        let byType = try await ids(board: "links")
        XCTAssertEqual(byType, [link.id])
        let byTopic = try await ids(board: "WORK")
        XCTAssertEqual(byTopic, [work.id])
        let empty = try await ids(board: "Empty")
        XCTAssertEqual(empty, [])
        let unknown = try await ids(board: "no such board")
        XCTAssertEqual(unknown, [])
        let combined = try await ids(query: "pan", board: "Recetas")
        XCTAssertEqual(combined, [recipe.id])
    }

    func testBoardsListPinboardsAndTheNonEmptySmartBoards() async throws {
        let recipe = try insert(.plainText, "pancakes", dt: 1)
        try insert(.url, "https://apple.com", dt: 2) { $0.smartKinds = SmartBoard.links.bit }
        try insert(.url, "https://swift.org", dt: 3) { $0.smartKinds = SmartBoard.links.bit }
        try pinboard("Recetas", [recipe])
        try pinboard("Empty", order: 1, [])

        let boards = try await library.boards()

        XCTAssertEqual(boards, [
            BoardSummary(id: nil, name: "Recetas", count: 1),
            BoardSummary(id: nil, name: "Empty", count: 0),
            BoardSummary(id: "links", name: SmartBoard.links.title, count: 2),
        ])
    }

    func testOnlyTheListedSmartBoardsShow() async throws {
        try insert(.url, "https://apple.com", dt: 1) { $0.smartKinds = SmartBoard.links.bit }
        library = StoreClipLibrary(container: container, smartBoards: { [] }) { _ in }

        let boards = try await library.boards()
        XCTAssertEqual(boards, [], "Automatic pinboards off: no smart board shows")
        let byBoard = try await ids(board: "links")
        XCTAssertEqual(byBoard, [])
    }

    // MARK: caps

    func testPreviewIsTheFirst200CharactersOrTheOCRTextOrLinkTitle() async throws {
        try insert(.plainText, String(repeating: "a", count: 1000), dt: 1)
        try insert(.image, nil, dt: 2) { $0.ocrText = "Text in the image" }
        try insert(.url, "https://example.com", dt: 3) { $0.linkTitle = "Example Domain" }

        let previews = try await library.search(query: nil, type: nil, board: nil, limit: 20).map(\.preview)

        XCTAssertEqual(previews, ["Example Domain", "Text in the image", String(repeating: "a", count: 200)])
    }

    func testAtMost50Results() async throws {
        for index in 0..<60 { try insert(.plainText, "clip \(index)", dt: TimeInterval(index)) }

        let capped = try await ids(limit: 80)
        XCTAssertEqual(capped.count, 50)
        let five = try await ids(limit: 5)
        XCTAssertEqual(five.count, 5)
    }

    func testFullTextIsCappedAt100KBAndSaysWhenItWasCut() async throws {
        let long = try insert(.plainText, String(repeating: "é", count: 60_000), dt: 1)  // 120 000 bytes
        let short = try insert(.plainText, "short", dt: 2)

        let cut = try await library.clip(id: long.id)
        let cutText = try XCTUnwrap(cut?.text)
        XCTAssertTrue(cut?.truncated == true)
        XCTAssertLessThanOrEqual(cutText.utf8.count, 100 * 1024)
        XCTAssertGreaterThan(cutText.utf8.count, 100 * 1024 - 2, "cut at the last whole character")
        XCTAssertTrue(cutText.allSatisfy { $0 == "é" })

        let whole = try await library.clip(id: short.id)
        XCTAssertEqual(whole?.text, "short")
        XCTAssertEqual(whole?.truncated, false)
    }


    // MARK: get_clip

    func testImageDetailReturnsOCRTextAndNoPixels() async throws {
        let png = Data(repeating: 0x89, count: 4096)
        let image = try insert(.image, nil, dt: 1, app: "Preview") {
            $0.rawData = png
            $0.thumbnailData = png
            $0.ocrText = "Hello from the image"
        }

        let detail = try await library.clip(id: image.id)

        XCTAssertEqual(detail, ClipDetail(id: image.id, type: .image, text: nil, truncated: false, app: "Preview",
                                          copiedAt: image.copiedAt, linkTitle: nil, ocrText: "Hello from the image", fileNames: []))
    }

    func testDetailCarriesTheLinkTitleAndFileNames() async throws {
        let link = try insert(.url, "https://example.com", dt: 1) { $0.linkTitle = "Example Domain" }
        let files = try insert(.files, "a.pdf, b.png", dt: 2) {
            $0.fileManifestData = try? JSONEncoder().encode([
                FileManifestEntry(name: "a.pdf", size: 1, uti: "com.adobe.pdf"),
                FileManifestEntry(name: "b.png", size: 1, uti: "public.png"),
            ])
        }
        let fileURL = try insert(.fileURL, "notes.txt", dt: 3)

        let linkDetail = try await library.clip(id: link.id)
        XCTAssertEqual(linkDetail?.linkTitle, "Example Domain")
        XCTAssertEqual(linkDetail?.text, "https://example.com")
        let filesDetail = try await library.clip(id: files.id)
        XCTAssertEqual(filesDetail?.fileNames, ["a.pdf", "b.png"])
        XCTAssertEqual(filesDetail?.type, .file)
        let fileURLDetail = try await library.clip(id: fileURL.id)
        XCTAssertEqual(fileURLDetail?.fileNames, ["notes.txt"])
    }

    func testAnUnknownIDIsNotFound() async throws {
        try insert(.plainText, "something", dt: 1)
        let detail = try await library.clip(id: UUID())
        XCTAssertNil(detail)
    }

    // MARK: copy_to_clipboard

    func testCopyWritesTheTextOnTheMainActor() async throws {
        let written = Written()
        library = StoreClipLibrary(container: container) { text in
            MainActor.assertIsolated()
            written.texts.append(text)
        }

        try await library.copy(text: "from an AI tool")

        XCTAssertEqual(written.texts, ["from an AI tool"])
    }

    /// The server switched off mid-request: the copy never lands.
    func testACancelledCopyWritesNothing() async throws {
        let written = Written()
        let library = StoreClipLibrary(container: container) { written.texts.append($0) }

        let copy = Task { try await library.copy(text: "too late") }
        copy.cancel()
        let result = await copy.result

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(written.texts, [])
    }
}

@MainActor
private final class Written {
    var texts: [String] = []
}
