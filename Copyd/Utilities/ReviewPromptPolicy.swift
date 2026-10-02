import Foundation

/// Decides when Clipbara may ask for an App Store rating.
///
/// Kept free of AppKit and StoreKit so the rules can be unit tested on their own.
/// Apple still decides whether the prompt actually appears (at most three times a
/// year per user), so this only filters out moments that are clearly too early.
struct ReviewPromptPolicy {
    static let minimumDaysSinceFirstLaunch = 7
    static let minimumPasteCount = 20
    /// The prompt is only considered right after the panel closed from a paste.
    static let recentPasteWindow: TimeInterval = 5

    enum Keys {
        static let firstLaunchDate = "reviewPrompt.firstLaunchDate"
        static let pasteCount = "reviewPrompt.pasteCount"
        static let lastPromptedVersion = "reviewPrompt.lastPromptedVersion"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var firstLaunchDate: Date? {
        defaults.object(forKey: Keys.firstLaunchDate) as? Date
    }

    var pasteCount: Int {
        defaults.integer(forKey: Keys.pasteCount)
    }

    var lastPromptedVersion: String? {
        defaults.string(forKey: Keys.lastPromptedVersion)
    }

    /// Records the first launch once. Later launches keep the original date.
    func noteLaunch(now: Date = .now) {
        guard firstLaunchDate == nil else { return }
        defaults.set(now, forKey: Keys.firstLaunchDate)
    }

    func recordPaste() {
        defaults.set(pasteCount + 1, forKey: Keys.pasteCount)
    }

    func markPrompted(version: String) {
        defaults.set(version, forKey: Keys.lastPromptedVersion)
    }

    /// Enough use to have an opinion, and not asked yet for this version.
    func isEligible(now: Date = .now, version: String) -> Bool {
        guard let firstLaunchDate else { return false }
        let minimumAge = TimeInterval(Self.minimumDaysSinceFirstLaunch * 24 * 60 * 60)
        guard now.timeIntervalSince(firstLaunchDate) >= minimumAge else { return false }
        guard pasteCount >= Self.minimumPasteCount else { return false }
        return lastPromptedVersion != version
    }

    /// True when the last paste happened moments ago, i.e. the panel is closing
    /// because the user just finished a task rather than dismissing it.
    static func isRecentPaste(_ pasteDate: Date?, now: Date = .now) -> Bool {
        guard let pasteDate else { return false }
        let elapsed = now.timeIntervalSince(pasteDate)
        return elapsed >= 0 && elapsed < recentPasteWindow
    }
}
