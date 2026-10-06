import AppKit
import XCTest

final class PanelTabShortcutTests: XCTestCase {
    func testNumberRowMapsToVisibleTabOrder() {
        let keys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, key) in keys.enumerated() {
            XCTAssertEqual(PanelTabShortcut.index(keyCode: key, modifiers: [.command, .option]), index)
        }
    }

    func testKeypadMapsToTheSameTabs() {
        let keys: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (index, key) in keys.enumerated() {
            XCTAssertEqual(PanelTabShortcut.index(keyCode: key, modifiers: [.command, .option, .numericPad]), index)
        }
    }

    func testRequiresCommandAndOption() {
        for flags: NSEvent.ModifierFlags in [[], .command, .option, [.command, .shift], .control] {
            XCTAssertNil(PanelTabShortcut.index(keyCode: 18, modifiers: flags))
        }
    }

    func testRejectsExtraChordModifiers() {
        for extra: NSEvent.ModifierFlags in [.shift, .control, [.shift, .control]] {
            XCTAssertNil(PanelTabShortcut.index(keyCode: 19, modifiers: [.command, .option, extra]))
        }
    }

    func testCapsLockDoesNotDisableShortcut() {
        XCTAssertEqual(PanelTabShortcut.index(keyCode: 18, modifiers: [.command, .option, .capsLock]), 0)
    }

    func testZeroAndOtherKeysAreNotTabShortcuts() {
        for key: UInt16 in [29, 82, 49, 36, 53, 123, 124, 0] {
            XCTAssertNil(PanelTabShortcut.index(keyCode: key, modifiers: [.command, .option]))
        }
    }

    func testHistoryWorksWithoutPinboards() {
        XCTAssertEqual(PanelTabShortcut.target(at: 0, pinboardIDs: []), .history)
        for index in 1..<9 {
            XCTAssertNil(PanelTabShortcut.target(at: index, pinboardIDs: []))
        }
    }

    func testPinboardsFollowSuppliedDisplayOrder() {
        let ids = (0..<10).map { _ in UUID() }
        for index in 1..<9 {
            XCTAssertEqual(PanelTabShortcut.target(at: index, pinboardIDs: ids), .pinboard(ids[index - 1]))
        }
        XCTAssertNil(PanelTabShortcut.target(at: 9, pinboardIDs: ids))
    }

    func testMissingAndOutOfRangeTabsAreNoOps() {
        let id = UUID()
        XCTAssertEqual(PanelTabShortcut.target(at: 1, pinboardIDs: [id]), .pinboard(id))
        XCTAssertNil(PanelTabShortcut.target(at: 2, pinboardIDs: [id]))
        XCTAssertNil(PanelTabShortcut.target(at: -1, pinboardIDs: [id]))
        XCTAssertNil(PanelTabShortcut.target(at: Int.max, pinboardIDs: [id]))
    }

    func testDeletingOrReorderingTabsUsesNewPositions() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(PanelTabShortcut.target(at: 1, pinboardIDs: [a, b, c]), .pinboard(a))
        XCTAssertEqual(PanelTabShortcut.target(at: 1, pinboardIDs: [b, c]), .pinboard(b))
        XCTAssertEqual(PanelTabShortcut.target(at: 2, pinboardIDs: [c, b]), .pinboard(b))
    }

    /// The automatic pinboards follow the user's pinboards, and the numbers keep counting through them.
    func testSmartBoardsContinueTheNumbering() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(PanelTabShortcut.target(at: 1, pinboardIDs: [a, b], smartBoards: [.links, .code]), .pinboard(a))
        XCTAssertEqual(PanelTabShortcut.target(at: 2, pinboardIDs: [a, b], smartBoards: [.links, .code]), .pinboard(b))
        XCTAssertEqual(PanelTabShortcut.target(at: 3, pinboardIDs: [a, b], smartBoards: [.links, .code]), .smart(.links))
        XCTAssertEqual(PanelTabShortcut.target(at: 4, pinboardIDs: [a, b], smartBoards: [.links, .code]), .smart(.code))
        XCTAssertNil(PanelTabShortcut.target(at: 5, pinboardIDs: [a, b], smartBoards: [.links, .code]))
        XCTAssertEqual(PanelTabShortcut.target(at: 1, pinboardIDs: [], smartBoards: [.images]), .smart(.images))
        let many = (0..<6).map { _ in UUID() }
        XCTAssertEqual(PanelTabShortcut.target(at: 8, pinboardIDs: many, smartBoards: SmartBoard.types), .smart(.code))
        XCTAssertNil(PanelTabShortcut.target(at: 9, pinboardIDs: many, smartBoards: SmartBoard.types), "⌥⌘9 is the last")
    }

    func testOnlyHistoryAndSmartBoardsShowTheHistoryGrid() {
        XCTAssertTrue(PanelTab.history.showsHistoryGrid)
        XCTAssertTrue(PanelTab.smart(.links).showsHistoryGrid)
        XCTAssertFalse(PanelTab.pinboard(UUID()).showsHistoryGrid)
        XCTAssertEqual(PanelTab.smart(.code).smartBoard, .code)
        XCTAssertNil(PanelTab.history.smartBoard)
    }

    func testHintsMatchShortcutRange() {
        for index in 0..<9 {
            XCTAssertEqual(PanelTabShortcut.hint(at: index), "⌥⌘\(index + 1)")
        }
        XCTAssertNil(PanelTabShortcut.hint(at: -1))
        XCTAssertNil(PanelTabShortcut.hint(at: 9))
    }
}
