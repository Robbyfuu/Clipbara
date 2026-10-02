import AppKit

enum PanelTab: Equatable, Hashable {
    case history
    case pinboard(UUID)
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

    static func target(at index: Int, pinboardIDs: [UUID]) -> PanelTab? {
        guard (0..<9).contains(index) else { return nil }
        if index == 0 { return .history }
        guard pinboardIDs.indices.contains(index - 1) else { return nil }
        return .pinboard(pinboardIDs[index - 1])
    }

    static func hint(at index: Int) -> String? {
        guard (0..<9).contains(index) else { return nil }
        return "⌥⌘\(index + 1)"
    }
}
