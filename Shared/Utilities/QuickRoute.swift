import Foundation

/// Where a Home Screen quick action or a `copyd://` link sends the app. The raw value is the URL host
/// and the suffix of the shortcut type in `CopydiOS/Info.plist`.
enum QuickRoute: String, Equatable {
    case saveClipboard = "save-clipboard", search, pinboards, keyboardSetup = "keyboard-setup"

    private static let shortcutPrefix = "com.robbyfuu.copyd."

    init?(url: URL) {
        guard url.scheme?.lowercased() == "copyd", let host = url.host() else { return nil }
        self.init(rawValue: host)
    }

    init?(shortcutType: String) {
        guard shortcutType.hasPrefix(Self.shortcutPrefix) else { return nil }
        self.init(rawValue: String(shortcutType.dropFirst(Self.shortcutPrefix.count)))
    }
}
