import Foundation

/// App Group defaults shared by the iOS app and the keyboard extension.
enum SharedDefaults {
    static let suiteName = "group.com.robbyfuu.copyd"
    static let lastSyncAtKey = "lastSyncAt"
    /// The `UIPasteboard.changeCount` Copyd has already handled: captured, declined, or written by Copyd itself.
    /// An `Int`, shared by the app and the keyboard, so each copy is read at most once.
    static let lastCapturedChangeCountKey = "lastCapturedPasteboardChange"
    static var store: UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// Records `changeCount` as handled. Returns false when it already was, so the caller leaves that copy alone.
    @discardableResult
    static func claimPasteboardChange(_ changeCount: Int, in defaults: UserDefaults? = store) -> Bool {
        guard defaults?.object(forKey: lastCapturedChangeCountKey) as? Int != changeCount else { return false }
        defaults?.set(changeCount, forKey: lastCapturedChangeCountKey)
        return true
    }
}
