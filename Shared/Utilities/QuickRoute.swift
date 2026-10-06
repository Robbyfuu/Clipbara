import Foundation

/// Where a Home Screen quick action or a `copyd://` link sends the app. A route's name is the URL host
/// and the suffix of the shortcut type in `CopydiOS/Info.plist`.
enum QuickRoute: Equatable {
    case saveClipboard, search, pinboards, keyboardSetup, history
    /// `copyd://copy/<uuid>`, from the widget, or a tapped Spotlight result. It only writes the pasteboard, so any link
    /// may open it.
    case copy(UUID)

    private static let shortcutPrefix = "com.robbyfuu.copyd."
    private static let named: [String: QuickRoute] = [
        "save-clipboard": .saveClipboard, "search": .search, "pinboards": .pinboards, "keyboard-setup": .keyboardSetup,
        "history": .history,
    ]

    /// A `copyd://` link may open any route but save: a web page must never make Copyd read the pasteboard.
    /// Save is reachable only in process, from the quick action and the App Intents.
    static func allowsURL(_ route: QuickRoute) -> Bool { route != .saveClipboard }

    static func copyURL(_ id: UUID) -> URL {
        URL(string: "copyd://copy/\(id.uuidString)")!  // a UUID string is always a valid path
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "copyd", let host = url.host()?.lowercased() else { return nil }
        if host == "copy" {
            // The path is exactly "/<uuid>": an empty, extra or malformed path is rejected.
            guard let id = UUID(uuidString: String(url.path().dropFirst())) else { return nil }
            self = .copy(id)
        } else {
            guard let route = Self.named[host] else { return nil }
            self = route
        }
    }

    /// CoreSpotlight's `CSSearchableItemActionType` and `CSSearchableItemActivityIdentifier`, spelled out so this file
    /// never links CoreSpotlight into the extensions. `QuickRouteTests` pins them to the real constants.
    static let spotlightActivityType = "com.apple.corespotlightitem"
    static let spotlightIDKey = "kCSSearchableItemActivityIdentifier"

    /// A tapped Spotlight result: copies its clip, whose UUID string is the entry's identifier.
    init?(activityType: String, userInfo: [AnyHashable: Any]?) {
        guard activityType == Self.spotlightActivityType,
              let id = (userInfo?[Self.spotlightIDKey] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        self = .copy(id)
    }

    init?(shortcutType: String) {
        guard shortcutType.hasPrefix(Self.shortcutPrefix),
              let route = Self.named[String(shortcutType.dropFirst(Self.shortcutPrefix.count))] else { return nil }
        self = route
    }
}
