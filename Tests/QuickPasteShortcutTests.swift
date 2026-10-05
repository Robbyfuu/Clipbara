import AppKit
import XCTest

final class QuickPasteShortcutTests: XCTestCase {
    func testCommandDigitsMapToNumbers() {
        XCTAssertEqual(QuickPasteShortcut.match(keyCode: 18, modifiers: .command),
                       .init(number: 0, plainText: false))
        XCTAssertEqual(QuickPasteShortcut.match(keyCode: 25, modifiers: .command)?.number, 8)
    }

    func testKeypadMatchesNumberRow() {
        let keys: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (n, key) in keys.enumerated() {
            XCTAssertEqual(QuickPasteShortcut.match(keyCode: key, modifiers: [.command, .numericPad]),
                           .init(number: n, plainText: false))
        }
    }

    func testShiftCommandIsPlainText() {
        XCTAssertEqual(QuickPasteShortcut.match(keyCode: 19, modifiers: [.command, .shift]),
                       .init(number: 1, plainText: true))
    }

    func testOtherChordsAreNotQuickPaste() {
        let chords: [NSEvent.ModifierFlags] = [[], .option, [.command, .option],
                                               [.command, .control], [.command, .shift, .option]]
        for flags in chords {
            XCTAssertNil(QuickPasteShortcut.match(keyCode: 18, modifiers: flags))
        }
    }

    func testCapsLockIsIgnored() {
        XCTAssertEqual(QuickPasteShortcut.match(keyCode: 18, modifiers: [.command, .capsLock]),
                       .init(number: 0, plainText: false))
    }

    func testZeroIsNotAShortcut() {
        XCTAssertNil(QuickPasteShortcut.match(keyCode: 29, modifiers: .command))
    }

    func testItemIndexOffsetsByFirstVisible() {
        XCTAssertEqual(QuickPasteShortcut.itemIndex(number: 2, firstVisibleIndex: 12, itemCount: 30), 14)
    }

    func testNumberPastEndIsNil() {
        XCTAssertNil(QuickPasteShortcut.itemIndex(number: 3, firstVisibleIndex: 0, itemCount: 3))
    }

    func testOutOfRangeNumberIsNil() {
        XCTAssertNil(QuickPasteShortcut.itemIndex(number: -1, firstVisibleIndex: 0, itemCount: 30))
        XCTAssertNil(QuickPasteShortcut.itemIndex(number: 9, firstVisibleIndex: 0, itemCount: 30))
    }

    func testHints() {
        for n in 0..<9 { XCTAssertEqual(QuickPasteShortcut.hint(number: n), "⌘\(n + 1)") }
        XCTAssertNil(QuickPasteShortcut.hint(number: -1))
        XCTAssertNil(QuickPasteShortcut.hint(number: 9))
    }

    /// ⌘N counts the cards as displayed: the three suggestions first, then the rest without them.
    func testCommandNumbersCountSuggestionsInFront() {
        struct Card: Identifiable, Equatable { let id: Int }
        let row = SuggestedRow.merge(suggested: [Card(id: 30), Card(id: 10), Card(id: 50)],
                                     rest: [10, 20, 30, 40, 50, 60].map(Card.init))
        func pasted(_ number: Int, firstVisible: Int = 0) -> Int? {
            QuickPasteShortcut.itemIndex(number: number, firstVisibleIndex: firstVisible, itemCount: row.count).map { row[$0].id }
        }
        XCTAssertEqual((0..<9).compactMap { pasted($0) }, [30, 10, 50, 20, 40, 60])
        // Scrolled one card along, ⌘1 is the second suggestion.
        XCTAssertEqual(pasted(0, firstVisible: 1), 10)
    }

    func testOptionOneToThreePasteSuggestions() {
        for (n, key) in ([18, 19, 20] as [UInt16]).enumerated() {
            XCTAssertEqual(QuickPasteShortcut.suggestion(keyCode: key, modifiers: .option), n)
        }
        XCTAssertEqual(QuickPasteShortcut.suggestion(keyCode: 84, modifiers: [.option, .numericPad]), 1)
        XCTAssertEqual(QuickPasteShortcut.suggestion(keyCode: 18, modifiers: [.option, .capsLock]), 0)
        XCTAssertNil(QuickPasteShortcut.suggestion(keyCode: 21, modifiers: .option), "⌥4 is not a suggestion")
        for flags: NSEvent.ModifierFlags in [[], .command, [.command, .option], [.option, .shift], [.option, .control]] {
            XCTAssertNil(QuickPasteShortcut.suggestion(keyCode: 18, modifiers: flags))
        }
    }

    func testFirstVisibleIndexFromOffset() {
        func f(_ o: CGFloat) -> Int {
            QuickPasteShortcut.firstVisibleIndex(scrollOffset: o, cardWidth: 200, spacing: 12, leadingPadding: 16)
        }
        XCTAssertEqual(f(0), 0)
        XCTAssertEqual(f(100), 1)
        XCTAssertEqual(f(130), 1)
        XCTAssertEqual(f(228), 1)
        XCTAssertEqual(f(229), 2)
        XCTAssertEqual(f(2846), 14)
        XCTAssertEqual(f(-40), 0)
    }

    // MARK: Card tools

    func testShiftOptionReturnOpensPasteAs() {
        XCTAssertEqual(CardShortcut.match(keyCode: 36, characters: "\r", modifiers: [.shift, .option]), .pasteAs)
        XCTAssertEqual(CardShortcut.match(keyCode: 36, characters: "\r", modifiers: [.shift, .option, .capsLock]), .pasteAs)
    }

    func testOtherReturnChordsAreNotCardTools() {
        // Return and ⇧Return paste.
        for flags: NSEvent.ModifierFlags in [[], .shift, [.shift, .option, .command], [.shift, .option, .control],
                                             [.option, .command], [.option, .control]] {
            XCTAssertNil(CardShortcut.match(keyCode: 36, characters: "\r", modifiers: flags), "\(flags)")
        }
    }

    func testOptionReturnCopiesText() {
        XCTAssertEqual(CardShortcut.match(keyCode: 36, characters: "\r", modifiers: .option), .copyText)
        XCTAssertEqual(CardShortcut.match(keyCode: 36, characters: "\r", modifiers: [.option, .capsLock]), .copyText)
        XCTAssertNil(CardShortcut.match(keyCode: 76, characters: "\u{3}", modifiers: .option), "keypad Enter is not Return")
    }

    func testCommandEEdits() {
        XCTAssertEqual(CardShortcut.match(keyCode: 14, characters: "e", modifiers: .command), .edit)
        XCTAssertEqual(CardShortcut.match(keyCode: 14, characters: "E", modifiers: [.command, .capsLock]), .edit)
        // Dvorak: E is a different key, and the key in E's place types a period.
        XCTAssertEqual(CardShortcut.match(keyCode: 2, characters: "e", modifiers: .command), .edit)
        XCTAssertNil(CardShortcut.match(keyCode: 14, characters: ".", modifiers: .command))
        for flags: NSEvent.ModifierFlags in [[], .shift, [.command, .shift], [.command, .option]] {
            XCTAssertNil(CardShortcut.match(keyCode: 14, characters: "e", modifiers: flags), "\(flags)")
        }
    }
}
