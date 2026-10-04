import CoreGraphics

/// What a pick from Copyd's UI does after the clip is on the pasteboard and the panel is closed.
///
/// Pure logic, kept free of AppKit so the unit test target can compile it.
enum AutoPastePolicy {
    enum Action: Equatable, Sendable {
        /// Post ⌘V to the app in front.
        case paste
        /// First pick without Accessibility: ask macOS once and tell the user to press ⌘V.
        case requestAccessAndHint
        /// Asked before and still not allowed: only tell the user to press ⌘V.
        case hintOnly
        /// The pick only copies.
        case none
    }

    /// - Parameters:
    ///   - enabled: The "Paste directly into the app" setting.
    ///   - hasAccess: Copyd may post keyboard events (Accessibility).
    ///   - copydIsActive: Copyd is the active app (its Settings window has focus), so ⌘V would land in Copyd.
    ///   - alreadyPrompted: macOS was already asked for access; it is asked only once.
    static func decide(enabled: Bool, hasAccess: Bool, copydIsActive: Bool, alreadyPrompted: Bool) -> Action {
        guard enabled, !copydIsActive else { return .none }
        if hasAccess { return .paste }
        return alreadyPrompted ? .hintOnly : .requestAccessAndHint
    }

    /// The app the user was in is frontmost again, so a ⌘V posted now reaches it.
    static func focusReady(frontmost: pid_t?, previous: pid_t?) -> Bool {
        guard let frontmost, let previous else { return false }
        return frontmost == previous
    }

    /// The panel is non-activating, so opening it takes the key window from the app in front without
    /// deactivating that app, and ordering it out gives the key window back to nobody. Re-activate the
    /// app the panel opened over, unless the panel opened over Copyd, the user clicked into another app,
    /// or a Copyd window (Settings, Paywall) took over.
    static func restoresFocus(target: pid_t?, frontmost: pid_t?, own: pid_t, copydInFront: Bool) -> Bool {
        guard let target, target != own, !copydInFront else { return false }
        return frontmost == target
    }

    /// Copyd is in front only while it is the active app, or when a titled window (Settings, Onboarding, Paywall)
    /// opened after the panel or the menu bar list did: Settings from the sync chip, before its activation lands.
    /// Copyd is an agent whose windows stay "visible" behind other apps, so one left open there doesn't count.
    static func copydInFront<Window: Hashable>(isActive: Bool, titledWindows: Set<Window>, titledAtOpen: Set<Window>) -> Bool {
        isActive || !titledWindows.isSubset(of: titledAtOpen)
    }
}

/// Tags the ⌘V that Copyd posts, so Paste Stack's tap never takes it for the user's own.
enum CopydSyntheticPaste {
    /// "Cpyd" in ASCII, stored in the event's `eventSourceUserData`.
    static let marker: Int64 = 0x4370_7964

    static func isMarked(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == marker
    }
}
