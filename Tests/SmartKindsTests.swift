import SwiftData
import XCTest

/// Review focus 3: prose never lands in Code, and a plain sentence with a phone number lands in Phones & Emails.
final class SmartKindsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// The boards a clip lands in.
    private func boards(_ type: ContentType, _ text: String?) -> [SmartBoard] {
        let kinds = SmartKinds.classify(contentType: type, text: text)
        return SmartBoard.allCases.filter { SmartKinds.members(of: $0, kinds: kinds, topic: nil) }
    }

    // MARK: Each kind

    func testLinks() {
        XCTAssertEqual(boards(.url, "https://www.apple.com"), [.links])
        XCTAssertEqual(boards(.plainText, "https://copyd.app/a?b=1"), [.links], "a text clip that is one bare link")
        XCTAssertEqual(boards(.plainText, "see https://copyd.app for more"), [], "a sentence with a link is not a link")
    }

    func testCode() {
        XCTAssertEqual(boards(.plainText, "func greet(_ name: String) {\n    print(name)\n}"), [.code])
        XCTAssertEqual(boards(.plainText, #"{"name": "Copyd", "count": 3}"#), [.code])
    }

    func testProseIsNotCode() {
        for prose in ["The quick brown fox jumps over the lazy dog.", "Meet at the north entrance, 10:30",
                      "- milk\n- eggs\n- bread", "Hello from Copyd", "I think we should ship it on Friday; the team agrees."] {
            XCTAssertFalse(boards(.plainText, prose).contains(.code), prose)
        }
    }

    func testAddresses() {
        XCTAssertEqual(boards(.plainText, "1 Infinite Loop, Cupertino, CA 95014"), [.addresses])
        XCTAssertEqual(boards(.plainText, "Av. Providencia 1234, Santiago, Chile"), [.addresses])
        XCTAssertFalse(boards(.plainText, "The quick brown fox jumps over the lazy dog.").contains(.addresses))
    }

    func testPlainSentenceWithAPhoneNumberLandsInContacts() {
        XCTAssertEqual(boards(.plainText, "Call me at (415) 555-0132 tomorrow"), [.contacts])
        XCTAssertEqual(boards(.plainText, "Llámame al +56 9 8765 4321 mañana"), [.contacts])
        XCTAssertEqual(boards(.html, "Call (415) 555-0132"), [.contacts], "rich text and HTML by their text")
    }

    func testEmailsLandInContacts() {
        XCTAssertEqual(boards(.plainText, "write to ana@example.com please"), [.contacts])
        XCTAssertEqual(boards(.plainText, "mailto:ana@example.com"), [.contacts])
    }

    func testNumbersAndDatesAreNotContacts() {
        for text in ["464501", "Order #12345678 shipped", "Meet at 10:30 on 2026-10-07", "version 1.2.3.4"] {
            XCTAssertEqual(boards(.plainText, text), [], text)
        }
    }

    func testTypeBoardsFollowTheClipType() {
        XCTAssertEqual(boards(.image, nil), [.images])
        XCTAssertEqual(boards(.color, "#F8D14F"), [.colors])
        XCTAssertEqual(boards(.files, "a.pdf\nCall (415) 555-0132.txt"), [.files], "a files clip's text is its names")
        XCTAssertEqual(boards(.fileURL, "file:///Users/ana/a.pdf"), [.files])
        XCTAssertEqual(boards(.unknown, "Call (415) 555-0132"), [])
        XCTAssertEqual(boards(.plainText, nil), [])
    }

    func testOneClipCanLandInSeveralBoards() {
        XCTAssertEqual(boards(.plainText, "Ana: ana@example.com, 1 Infinite Loop, Cupertino, CA 95014"),
                       [.addresses, .contacts])
    }

    func testOnlyTheFirst4KBIsScanned() {
        let padding = String(repeating: "word ", count: 1000)  // 5,000 bytes
        XCTAssertEqual(boards(.plainText, padding + "Call me at (415) 555-0132"), [])
        XCTAssertEqual(boards(.plainText, "Call me at (415) 555-0132 " + padding), [.contacts])
    }

    // MARK: Boards

    func testBoardsInSpecOrder() {
        XCTAssertEqual(SmartBoard.allCases.map(\.rawValue),
                       ["links", "code", "addresses", "contacts", "images", "colors", "files",
                        "work", "shopping", "travel", "finance", "study", "social", "personal"])
        XCTAssertEqual(SmartBoard.types, [.links, .code, .addresses, .contacts, .images, .colors, .files])
        XCTAssertEqual(SmartBoard.allCases.filter(\.isTopic), [.work, .shopping, .travel, .finance, .study, .social, .personal])
    }

    func testTitlesMatchTheSpec() throws {
        XCTAssertEqual(SmartBoard.allCases.map(\.title),
                       ["Links", "Code", "Addresses", "Phones & Emails", "Images", "Colors", "Files",
                        "Work", "Shopping", "Travel", "Finance", "Study", "Social", "Personal"])
        // The test bundle carries the iPhone's catalog: its es.lproj gives Spanish whatever this Mac's language is.
        let path = try XCTUnwrap(Bundle(for: Self.self).path(forResource: "es", ofType: "lproj"))
        let es = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(SmartBoard.allCases.map { $0.title(bundle: es) },
                       ["Enlaces", "Código", "Direcciones", "Teléfonos y correos", "Imágenes", "Colores", "Archivos",
                        "Trabajo", "Compras", "Viajes", "Finanzas", "Estudio", "Social", "Personal"])
    }

    func testMembers() {
        let kinds = SmartBoard.code.bit | SmartBoard.contacts.bit
        XCTAssertEqual(SmartBoard.allCases.filter { SmartKinds.members(of: $0, kinds: kinds, topic: nil) }, [.code, .contacts])
        XCTAssertTrue(SmartKinds.members(of: .work, kinds: 0, topic: "work"))
        XCTAssertFalse(SmartKinds.members(of: .work, kinds: 0, topic: "shopping"))
        XCTAssertFalse(SmartKinds.members(of: .work, kinds: kinds, topic: nil))
        XCTAssertFalse(SmartKinds.members(of: .links, kinds: 0, topic: "links"), "a type board follows the kinds only")
        XCTAssertEqual(Set(SmartBoard.types.map(\.bit)).count, 7, "one bit per type board")
    }

    // MARK: Fill plan

    private func clip(_ minutesAgo: Int, version: Int = 0) -> (id: UUID, version: Int, copiedAt: Date) {
        (UUID(), version, now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    }

    func testBatchIsTheNewestClipsNotYetClassified() {
        let a = clip(0), done = clip(1, version: SmartKinds.version), b = clip(2), c = clip(3)
        XCTAssertEqual(SmartKinds.nextBatch(clips: [c, done, b, a], limit: 2), [a.id, b.id])
    }

    func testBatchHolds50AmongTheNewest1000() {
        XCTAssertEqual(SmartKinds.version, 1)
        let clips = (0..<1100).map { clip($0) }
        XCTAssertEqual(SmartKinds.nextBatch(clips: clips.shuffled()), clips.prefix(50).map(\.id))
        let newestDone = clips.enumerated().map { $0.offset < 1000 ? ($0.element.id, SmartKinds.version, $0.element.copiedAt) : $0.element }
        XCTAssertEqual(SmartKinds.nextBatch(clips: newestDone), [], "past the newest 1,000, never classified")
    }

    /// Bumping `SmartKinds.version` sorts every clip again.
    func testVersionBumpClassifiesAgain() {
        let done = clip(0, version: 1)
        XCTAssertEqual(SmartKinds.nextBatch(clips: [done], version: 1), [])
        XCTAssertEqual(SmartKinds.nextBatch(clips: [done], version: 2), [done.id])
    }
}

/// The fill pass: newest first, 50 at a time, written with the local-only save. Never in an extension.
@MainActor
final class SmartKindsQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var saves: [Set<UUID>] = []
    private var enabled = true

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        saves = []
        enabled = true
    }

    @discardableResult
    private func insert(_ type: ContentType, _ text: String?, dt: TimeInterval = 0) throws -> ClipboardItem {
        let item = ClipboardItem(contentType: type, rawData: Data((text ?? "").utf8), textContent: text,
                                 contentHash: UUID().uuidString)
        item.copiedAt = Date(timeIntervalSince1970: 1_800_000_000 + dt)
        container.mainContext.insert(item)
        try container.mainContext.save()
        return item
    }

    private func makeQueue() -> SmartKindsQueue {
        SmartKindsQueue(container: container, isEnabled: { [unowned self] in enabled }) { [unowned self] ids in
            saves.append(ids)
            try? container.mainContext.save()
        }
    }

    private func finish(_ queue: SmartKindsQueue) async {
        while let task = queue.task { await task.value }
    }

    func testFillSortsEachClipAndSavesLocalOnly() async throws {
        let link = try insert(.url, "https://www.apple.com", dt: 3)
        let phone = try insert(.plainText, "Call me at (415) 555-0132", dt: 2)
        let prose = try insert(.plainText, "Hello from Copyd", dt: 1)
        let image = try insert(.image, nil, dt: 0)
        let queue = makeQueue()
        queue.fill()
        await finish(queue)
        XCTAssertEqual(link.smartKinds, SmartBoard.links.bit)
        XCTAssertEqual(phone.smartKinds, SmartBoard.contacts.bit)
        XCTAssertEqual(prose.smartKinds, 0)
        XCTAssertEqual(image.smartKinds, SmartBoard.images.bit)
        XCTAssertTrue([link, phone, prose, image].allSatisfy { $0.smartKindsVersion == SmartKinds.version },
                      "a clip in no board is sorted too, and never again")
        XCTAssertEqual(saves, [[link.id, phone.id, prose.id, image.id]], "one batch, through the local-only save")
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testFillRunsInBatchesOf50() async throws {
        for i in 0..<120 { try insert(.plainText, "note \(i)", dt: TimeInterval(i)) }
        let queue = makeQueue()
        queue.fill()
        await finish(queue)
        XCTAssertEqual(saves.map(\.count), [50, 50, 20])
    }

    /// A clip sorted by an older classifier is sorted again; a second fill finds nothing to do.
    func testOlderVersionIsSortedAgain() async throws {
        let clip = try insert(.plainText, "Call me at (415) 555-0132")
        clip.smartKinds = SmartBoard.code.bit
        clip.smartKindsVersion = SmartKinds.version - 1
        try container.mainContext.save()
        let queue = makeQueue()
        queue.fill()
        await finish(queue)
        XCTAssertEqual(clip.smartKinds, SmartBoard.contacts.bit)
        XCTAssertEqual(clip.smartKindsVersion, SmartKinds.version)
        queue.fill()
        await finish(queue)
        XCTAssertEqual(saves.count, 1)
    }

    /// A secret is sorted by its type only: its text never lands it in Code or Phones & Emails.
    func testSecretsAreSortedByTypeOnly() async throws {
        let secret = try insert(.plainText, "Call me at (415) 555-0132")
        secret.isSensitive = true
        try container.mainContext.save()
        let queue = makeQueue()
        queue.fill()
        await finish(queue)
        XCTAssertEqual(secret.smartKinds, 0)
        XCTAssertEqual(secret.smartKindsVersion, SmartKinds.version)
    }

    func testNothingRunsWhileTurnedOff() async throws {
        let link = try insert(.url, "https://www.apple.com")
        enabled = false
        let queue = makeQueue()
        queue.fill()
        XCTAssertNil(queue.task)
        XCTAssertEqual(link.smartKindsVersion, 0)
    }

    func testFillWhileAPassRunsNeverStartsASecond() async throws {
        try insert(.url, "https://www.apple.com")
        let queue = makeQueue()
        queue.fill()
        let first = queue.task
        queue.fill()
        XCTAssertNotNil(first)
        XCTAssertEqual(queue.task, first)
        await finish(queue)
        XCTAssertEqual(saves.count, 1)
    }
}
