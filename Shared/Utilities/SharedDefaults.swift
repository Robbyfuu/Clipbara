import Foundation

/// App Group defaults shared by the iOS app and the keyboard extension.
enum SharedDefaults {
    static let suiteName = "group.com.robbyfuu.copyd"
    static let lastSyncAtKey = "lastSyncAt"
    /// The `UIPasteboard.changeCount` Copyd has already handled: captured, declined, or written by Copyd itself.
    /// An `Int`, shared by the app and the keyboard, so each copy is read at most once.
    static let lastCapturedChangeCountKey = "lastCapturedPasteboardChange"
    /// A `Date` the keyboard writes each time it loads with Full Access. The App Group is writable only with
    /// Full Access, so the app takes its presence as proof.
    static let keyboardFullAccessSeenAtKey = "keyboardFullAccessSeenAt"
    static var store: UserDefaults? { UserDefaults(suiteName: suiteName) }

    /// Records `changeCount` as handled. Returns false when it already was, so the caller leaves that copy alone.
    @discardableResult
    static func claimPasteboardChange(_ changeCount: Int, in defaults: UserDefaults? = store) -> Bool {
        // Without the App Group nothing can be remembered, so claiming nothing keeps the app from reading on every activation.
        guard let defaults else { return false }
        guard defaults.object(forKey: lastCapturedChangeCountKey) as? Int != changeCount else { return false }
        defaults.set(changeCount, forKey: lastCapturedChangeCountKey)
        return true
    }

    enum PasteboardAction: Equatable { case skip, leaveForApp, claim }

    /// What a reader does with the current copy. A process that never reads images (the keyboard) leaves one
    /// unclaimed and unread, so the app captures it the next time it opens.
    static func pasteboardAction(hasImages: Bool, readsImages: Bool, changeCount: Int, stored: Int?) -> PasteboardAction {
        if stored == changeCount { return .skip }
        return hasImages && !readsImages ? .leaveForApp : .claim
    }
}
