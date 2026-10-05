import AppKit

/// Physical digit keys 1 through 9: number row and numeric keypad (no zero).
enum NumberKey {
    private static let numberRow: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let keypad: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]

    /// 0...8 for "1"..."9", nil for any other key.
    static func index(keyCode: UInt16) -> Int? {
        numberRow.firstIndex(of: keyCode) ?? keypad.firstIndex(of: keyCode)
    }
}

/// Panel-local quick paste of visible cards: ⌘1-9, or ⇧⌘1-9 for plain text.
/// Caps Lock and the keypad flag are ignored; any other modifier is not a match.
enum QuickPasteShortcut {
    struct Match: Equatable {
        let number: Int
        let plainText: Bool
    }

    static func match(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Match? {
        let chord = modifiers.intersection([.command, .option, .control, .shift])
        let plainText: Bool
        switch chord {
        case .command: plainText = false
        case [.command, .shift]: plainText = true
        default: return nil
        }
        guard let number = NumberKey.index(keyCode: keyCode) else { return nil }
        return Match(number: number, plainText: plainText)
    }

    /// ⌥1-3 pastes suggestion 1-3: 0...2. ⌥⌘ stays the tab switch (PanelTabShortcut).
    static func suggestion(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard modifiers.intersection([.command, .option, .control, .shift]) == .option,
              let number = NumberKey.index(keyCode: keyCode), number < 3 else { return nil }
        return number
    }

    static func itemIndex(number: Int, firstVisibleIndex: Int, itemCount: Int) -> Int? {
        guard (0..<9).contains(number) else { return nil }
        let index = firstVisibleIndex + number
        return index < itemCount ? index : nil
    }

    /// Leftmost card whose left edge is at or right of the scroll view's leading edge, so its badge is fully visible.
    static func firstVisibleIndex(scrollOffset: CGFloat, cardWidth: CGFloat, spacing: CGFloat, leadingPadding: CGFloat) -> Int {
        max(0, Int(ceil((scrollOffset - leadingPadding) / (cardWidth + spacing))))
    }

    static func hint(number: Int) -> String? {
        guard (0..<9).contains(number) else { return nil }
        return "⌘\(number + 1)"
    }
}
