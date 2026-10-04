import Foundation

/// The chip a Settings permissions row shows, from the raw checks.
enum PermissionStatus: Equatable, Sendable {
    case granted
    case missing
    /// The feature that needs the permission is off: the row is informational only.
    case notNeeded
    /// No API can tell: neutral, never a warning.
    case unconfirmed

    /// The keyboard extension's bundle ID, as iOS lists it in `AppleKeyboards`.
    static let copydKeyboardID = "com.robbyfuu.copyd.keyboard"

    /// A permission only matters while the feature that uses it is on.
    static func resolve(granted: Bool, featureOn: Bool) -> PermissionStatus {
        guard featureOn else { return .notNeeded }
        return granted ? .granted : .missing
    }

    /// iOS: the Copyd keyboard is added. `enabledKeyboards` is the `AppleKeyboards` default.
    static func resolve(enabledKeyboards: [String]?) -> PermissionStatus {
        enabledKeyboards?.contains(copydKeyboardID) == true ? .granted : .missing
    }

    /// iOS: the keyboard records a date each time it loads with Full Access. It can't write the App Group
    /// without it, so a date proves access; none may only mean the keyboard hasn't opened since.
    static func resolve(fullAccessSeenAt: Date?) -> PermissionStatus {
        fullAccessSeenAt == nil ? .unconfirmed : .granted
    }
}
