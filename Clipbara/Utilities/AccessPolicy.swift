import Foundation

/// Whether the Mac App Store build lets the user open their clipboard history.
///
/// Only the App Store build ever evaluates this. The DMG and Homebrew builds are
/// always fully unlocked and never reference it; it stays outside `#if APPSTORE`
/// so the unit test target can compile it.
enum AccessState: Equatable, Sendable {
    enum UnlockReason: Equatable, Sendable {
        /// First got the app before the trial model shipped, free or paid.
        case grandfathered
        /// Bought the one-time lifetime unlock.
        case lifetime
        /// A StoreKit check failed or could not be verified. An error never locks
        /// anyone out, so this counts as unlocked until a later check succeeds.
        case unverified
    }

    case unlocked(UnlockReason)
    case trialActive(daysLeft: Int)
    case trialNotStarted
    case trialExpired

    var allowsHistoryAccess: Bool {
        switch self {
        case .unlocked, .trialActive: true
        case .trialNotStarted, .trialExpired: false
        }
    }
}

/// Pure rules for the free trial and the one-time unlock.
///
/// Kept free of StoreKit so every branch can be unit tested with plain values.
enum AccessPolicy {
    static let trialDays = 7
    static let trialDuration: TimeInterval = TimeInterval(trialDays) * 24 * 60 * 60

    /// The first version sold with the trial. Anyone whose original App Store
    /// version is older keeps full access for good.
    ///
    /// On macOS, `AppTransaction.originalAppVersion` holds the original
    /// `CFBundleShortVersionString` (not `CFBundleVersion`), so this compares
    /// marketing versions.
    static let trialModelVersion = "1.4"

    /// Defensive fallback in case `originalAppVersion` ever carries a bare
    /// `CFBundleVersion` instead. Every App Store build before 1.4 (22, 23, 26,
    /// 28, 29) is below this. Update it if 1.4 ships with a different build number.
    static let trialModelBuildNumber = 31
    /// A single component at least this large is read as a build number. No
    /// marketing version of Clipbara comes anywhere close.
    private static let bareBuildNumberThreshold = 20

    /// - Parameters:
    ///   - isGrandfathered: `nil` when the app transaction could not be read or verified.
    ///   - hasLifetime: `nil` when the purchase history could not be read or verified.
    ///   - trialStart: When the $0 trial was taken. Only meaningful when `hasLifetime` is known.
    /// - Returns: A locked state only when every input is positively known.
    static func state(
        isGrandfathered: Bool?,
        hasLifetime: Bool?,
        trialStart: Date?,
        now: Date
    ) -> AccessState {
        if hasLifetime == true { return .unlocked(.lifetime) }
        if isGrandfathered == true { return .unlocked(.grandfathered) }
        guard isGrandfathered != nil, hasLifetime != nil else { return .unlocked(.unverified) }

        guard let trialStart else { return .trialNotStarted }
        let remaining = trialEnd(from: trialStart).timeIntervalSince(now)
        guard remaining > 0 else { return .trialExpired }
        return .trialActive(daysLeft: daysLeft(remaining: remaining))
    }

    static func trialEnd(from start: Date) -> Date {
        start.addingTimeInterval(trialDuration)
    }

    /// Whole days left, rounded up so the last few hours still read "1 day".
    /// Capped at the trial length in case the start date is ahead of this Mac's clock.
    static func daysLeft(remaining: TimeInterval) -> Int {
        let days = Int((remaining / (24 * 60 * 60)).rounded(.up))
        return min(trialDays, max(1, days))
    }

    /// Where the customer first got the app (`AppTransaction.originalPlatform`,
    /// macOS 15.4 and later). `unknown` on older systems.
    enum OriginalPlatform: Sendable {
        case mac
        case other
        case unknown
    }

    /// Clipbara was only sold before 1.4 on the Mac. With universal purchase, someone
    /// who first got it on iPhone never had the old Mac app, whatever version string the
    /// App Store reports for them (the iPhone app's own versions could read as older
    /// than 1.4). Without the platform, fall back to the version alone.
    static func isGrandfathered(originalAppVersion: String, originalPlatform: OriginalPlatform) -> Bool? {
        if originalPlatform == .other { return false }
        return isGrandfathered(originalAppVersion: originalAppVersion)
    }

    /// `nil` when the version string can't be parsed, which callers treat as unknown.
    static func isGrandfathered(originalAppVersion: String) -> Bool? {
        guard let original = versionComponents(originalAppVersion),
              let cutoff = versionComponents(trialModelVersion) else { return nil }
        if original.count == 1, original[0] >= bareBuildNumberThreshold {
            return original[0] < trialModelBuildNumber
        }
        let length = max(original.count, cutoff.count)
        let lhs = original + Array(repeating: 0, count: length - original.count)
        let rhs = cutoff + Array(repeating: 0, count: length - cutoff.count)
        return lhs.lexicographicallyPrecedes(rhs)
    }

    /// "1.3.3" -> [1, 3, 3]. Rejects empty, negative, or non-numeric components.
    static func versionComponents(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var components: [Int] = []
        for part in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else {
                return nil
            }
            components.append(value)
        }
        return components
    }
}
