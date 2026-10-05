import SwiftData
import XCTest

@MainActor
final class MultiPasteTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func clip(_ type: ContentType, _ text: String?) -> ClipboardItem {
        let item = ClipboardItem(contentType: type, rawData: Data((text ?? "").utf8), textContent: text, contentHash: UUID().uuidString)
        container.mainContext.insert(item)
        return item
    }

    // MARK: - Join

    func testJoinsInSelectionOrder() throws {
        let a = clip(.plainText, "a"), b = clip(.plainText, "b"), c = clip(.plainText, "c")
        let joined = try XCTUnwrap(MultiPaste.join([c, a, b], separator: .newline))
        XCTAssertEqual(joined.text, "c\na\nb")
        XCTAssertEqual(joined.skipped, 0)
    }

    func testEachSeparator() {
        let items = [clip(.plainText, "x"), clip(.plainText, "y")]
        let expected: [(Separator, String)] = [(.newline, "x\ny"), (.space, "x y"), (.comma, "x, y"), (.tab, "x\ty")]
        for (separator, text) in expected {
            XCTAssertEqual(MultiPaste.join(items, separator: separator)?.text, text, "\(separator)")
        }
    }

    func testCustomUnescapes() {
        XCTAssertEqual(Separator.custom(#"\n---\n"#).string, "\n---\n")
        XCTAssertEqual(Separator.custom(#" |\t"#).string, " |\t")
        XCTAssertEqual(Separator.custom(" / ").string, " / ")
        let items = [clip(.plainText, "x"), clip(.plainText, "y")]
        XCTAssertEqual(MultiPaste.join(items, separator: .custom(#"\t;"#))?.text, "x\t;y")
    }

    func testSkipsNonText() throws {
        let items = [
            clip(.plainText, "text"), clip(.image, nil), clip(.richText, "rich"), clip(.html, "html"),
            clip(.url, "https://copyd.app"), clip(.fileURL, "file.pdf"), clip(.color, "#F8D14F"),
        ]
        let joined = try XCTUnwrap(MultiPaste.join(items, separator: .space))
        XCTAssertEqual(joined.text, "text rich html https://copyd.app #F8D14F")
        XCTAssertEqual(joined.skipped, 2)
    }

    func testAllNonTextJoinsToNil() {
        XCTAssertNil(MultiPaste.join([clip(.image, nil), clip(.fileURL, "a.pdf"), clip(.files, "b.pdf")], separator: .newline))
        XCTAssertNil(MultiPaste.join([], separator: .newline))
    }

    func testSeparatorIsRemembered() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MultiPasteTests"))
        defaults.removePersistentDomain(forName: "MultiPasteTests")
        XCTAssertEqual(Separator.saved(in: defaults), .newline, "default")
        Separator.custom(#"\n--"#).save(in: defaults)
        XCTAssertNotNil(defaults.data(forKey: "multiPasteSeparator"))
        XCTAssertEqual(Separator.saved(in: defaults), .custom(#"\n--"#))
        Separator.comma.save(in: defaults)
        XCTAssertEqual(Separator.saved(in: defaults), .comma)
    }

    // MARK: - Selection

    private let ids = (0..<6).map { _ in UUID() }

    func testCommandClickAddsTheFocusedCardFirst() {
        var selection = MultiSelection()
        XCTAssertEqual(selection.toggle(3, focus: 1, in: ids), 3)
        XCTAssertEqual(selection.ids, [ids[1], ids[3]])
        XCTAssertEqual(selection.toggle(0, focus: 3, in: ids), 0)
        XCTAssertEqual(selection.ids, [ids[1], ids[3], ids[0]])
        XCTAssertEqual(selection.number(of: ids[0]), 3)
        XCTAssertNil(selection.number(of: ids[2]))
    }

    func testOneCardLeftCollapsesToSingleSelection() {
        var selection = MultiSelection()
        _ = selection.toggle(3, focus: 1, in: ids)
        XCTAssertEqual(selection.toggle(3, focus: 3, in: ids), 1, "focus moves to the card left")
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertEqual(selection.toggle(2, focus: 2, in: ids), 2, "the focused card alone is no multi-selection")
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testShiftExtendsFromTheAnchorInOrder() {
        var selection = MultiSelection()
        XCTAssertEqual(selection.extend(to: 1, focus: 3, in: ids), 1)
        XCTAssertEqual(selection.ids, [ids[3], ids[2], ids[1]])
        XCTAssertEqual(selection.extend(to: 5, focus: 1, in: ids), 5, "the anchor stays put")
        XCTAssertEqual(selection.ids, [ids[3], ids[4], ids[5]])
        _ = selection.extend(to: 3, focus: 5, in: ids)
        XCTAssertTrue(selection.ids.isEmpty, "back to the anchor alone")
        selection.clear()
        _ = selection.extend(to: 1, focus: 0, in: ids)
        XCTAssertEqual(selection.ids, [ids[0], ids[1]], "clear drops the anchor")
    }

    func testShiftClickKeepsEarlierCommandPicks() {
        var selection = MultiSelection()
        _ = selection.toggle(2, focus: 0, in: ids)
        XCTAssertEqual(selection.extend(to: 4, focus: 2, in: ids), 4, "the range starts at the last ⌘-picked card")
        XCTAssertEqual(selection.ids, [ids[0], ids[2], ids[3], ids[4]])
    }

    func testItemsResolveInSelectionOrderAndDropMissing() {
        let a = clip(.plainText, "a"), b = clip(.plainText, "b"), c = clip(.plainText, "c")
        var selection = MultiSelection()
        _ = selection.toggle(0, focus: 2, in: [a, b, c].map(\.id))
        XCTAssertEqual(selection.items(in: [a, b, c]).map(\.id), [c.id, a.id])
        XCTAssertEqual(selection.items(in: [a, b]).map(\.id), [a.id])
    }
}
