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

    /// iOS: the Copyd keyboard is added. `enabledKeyboards` is the `AppleKeyboards` default, which iOS may not expose:
    /// no list at all is neutral. A Full Access date proves the keyboard ran, so it is added whatever the list says.
    static func resolve(enabledKeyboards: [String]?, fullAccessSeenAt: Date?) -> PermissionStatus {
        if fullAccessSeenAt != nil { return .granted }
        guard let enabledKeyboards else { return .unconfirmed }
        return enabledKeyboards.contains(copydKeyboardID) ? .granted : .missing
    }

    /// How long a Full Access record counts: an older one may predate the user turning Full Access off.
    static let fullAccessFreshness: TimeInterval = 7 * 86_400

    /// iOS: the keyboard records a date when it appears with Full Access. It can't write the App Group without it,
    /// so a recent date proves access; none, or an old one, may only mean the keyboard hasn't opened since.
    static func resolve(fullAccessSeenAt: Date?, now: Date) -> PermissionStatus {
        guard let fullAccessSeenAt, now.timeIntervalSince(fullAccessSeenAt) < fullAccessFreshness else { return .unconfirmed }
        return .granted
    }

    /// The keyboard rewrites its Full Access date at most once a day.
    static func shouldRecordFullAccess(seenAt: Date?, now: Date) -> Bool {
        guard let seenAt else { return true }
        return now.timeIntervalSince(seenAt) > 86_400
    }
}
