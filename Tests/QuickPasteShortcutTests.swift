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
}
