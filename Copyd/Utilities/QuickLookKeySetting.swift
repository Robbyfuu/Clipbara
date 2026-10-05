import AppKit

/// Stores the user-configurable panel-local key that toggles Quick Look preview.
/// Unlike the global panel shortcut (KeyboardShortcuts), this is a single key
/// consumed by the panel's local event monitor while the panel is visible.
enum QuickLookKeySetting {
    static let defaultsKey = "quickLookKeyCode"
    static let defaultKeyCode: UInt16 = 49 // Space

    /// Keys the panel already uses for navigation, or that would break expectations.
    static let reservedKeyCodes: Set<UInt16> = [
        53,  // Escape
        36,  // Return
        76,  // Keypad Enter
        48,  // Tab
        123, 124, 125, 126, // Arrows
    ]

    static var keyCode: UInt16 {
        get {
            guard UserDefaults.standard.object(forKey: defaultsKey) != nil else {
                return defaultKeyCode
            }
            let stored = UserDefaults.standard.integer(forKey: defaultsKey)
            guard let value = UInt16(exactly: stored), !reservedKeyCodes.contains(value) else {
                return defaultKeyCode
            }
            return value
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: defaultsKey)
        }
    }

    /// Whether the key has a readable name. Keys without one fall back to "Key 42"
    /// and are rejected by the recorder.
    static func hasKnownName(_ keyCode: UInt16) -> Bool {
        keyCode == 49 || keyNames[keyCode] != nil
    }

    static func displayName(for keyCode: UInt16) -> String {
        if keyCode == 49 { return String(localized: "Space") }
        return keyNames[keyCode] ?? String(localized: "Key \(Int(keyCode))")
    }

    /// ANSI-layout key names for the keys users are likely to pick.
    private static let keyNames: [UInt16: String] = [
        49: "Space", 51: "⌫", 117: "⌦", 50: "`",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
        34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O",
        35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V",
        13: "W", 7: "X", 16: "Y", 6: "Z",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
        26: "7", 28: "8", 25: "9", 29: "0",
        27: "-", 24: "=", 33: "[", 30: "]", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/", 42: "\\",
    ]
}
