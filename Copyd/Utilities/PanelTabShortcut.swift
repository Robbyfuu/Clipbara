import AppKit

enum PanelTab: Equatable, Hashable {
    case history
    case pinboard(UUID)
    /// An automatic pinboard: History narrowed to one kind of clip, in the History grid. Read-only.
    case smart(SmartBoard)

    /// History and the automatic pinboards share the History grid; a pinboard has its own.
    var showsHistoryGrid: Bool {
        if case .pinboard = self { return false }
        return true
    }

    var smartBoard: SmartBoard? {
        if case .smart(let board) = self { return board }
        return nil
    }
}

/// Fixed panel-local shortcuts, in the same order as the visible tabs.
/// No global hotkeys are registered for tab navigation.
enum PanelTabShortcut {
    static func index(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        let chord = modifiers.intersection([.command, .option, .control, .shift])
        // ⌥⌘1-9. Caps Lock and the keypad flag do not change the shortcut;
        // extra modifiers do. Plain ⌘1-9 is quick paste (QuickPasteShortcut).
        guard chord == [.command, .option] else { return nil }
        return NumberKey.index(keyCode: keyCode)
    }

    /// History, then the pinboards, then the automatic pinboards, each in display order.
    static func target(at index: Int, pinboardIDs: [UUID], smartBoards: [SmartBoard] = []) -> PanelTab? {
        guard (0..<9).contains(index) else { return nil }
        if index == 0 { return .history }
        let tabs = pinboardIDs.map(PanelTab.pinboard) + smartBoards.map(PanelTab.smart)
        return tabs.indices.contains(index - 1) ? tabs[index - 1] : nil
    }

    static func hint(at index: Int) -> String? {
        guard (0..<9).contains(index) else { return nil }
        return "⌥⌘\(index + 1)"
    }
}
