import AppKit
import StoreKit

/// Asks for an App Store rating with Apple's own review prompt.
///
/// Only the Mac App Store build ever shows the prompt: other builds
/// can't rate the App Store listing. Usage is still counted in every build so the
/// logic stays identical, it just never presents outside the App Store build.
@MainActor
enum ReviewPrompter {
    static let appStoreID = "6803537696"

    /// Opens the App Store listing on its "Write a Review" page.
    static let writeReviewURL = URL(string: "macappstore://apps.apple.com/app/id\(appStoreID)?action=write-review")!
    static let feedbackURL = URL(string: "https://github.com/Robbyfuu/Clipbara/issues")!

    /// How long to wait after the panel closes, so the prompt never lands on top
    /// of the paste the user is about to make.
    static let presentationDelay: Duration = .seconds(3)

    private static var lastPasteDate: Date?
    private static var pendingPrompt: Task<Void, Never>?
    private static var hostWindow: NSWindow?

    private static var policy: ReviewPromptPolicy { ReviewPromptPolicy() }

    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static func noteLaunch() {
        policy.noteLaunch()
    }

    static func recordPaste() {
        policy.recordPaste()
        lastPasteDate = .now
    }

    /// Called as the history panel starts to hide.
    static func panelWillHide(isPanelVisible: @escaping @MainActor () -> Bool) {
        guard ReviewPromptPolicy.isRecentPaste(lastPasteDate),
              policy.isEligible(version: currentVersion) else { return }

        pendingPrompt?.cancel()
        pendingPrompt = Task { @MainActor in
            try? await Task.sleep(for: presentationDelay)
            guard !Task.isCancelled,
                  !isPanelVisible(),
                  policy.isEligible(version: currentVersion) else { return }
            present()
        }
    }

    /// Copyd is a menu bar agent with no window of its own, and StoreKit wants a
    /// view controller to present from. Host the request in a tiny transparent
    /// window. It is ordered in without activating the app, so the user's focus
    /// stays in the app they just pasted into.
    private static func present() {
        policy.markPrompted(version: currentVersion)

        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))

        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.borderless]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.setContentSize(NSSize(width: 1, height: 1))
        window.center()
        window.orderFrontRegardless()
        hostWindow = window

        AppStore.requestReview(in: controller)

        // Keep the host alive while StoreKit may be showing its sheet, then clean up.
        // If no sheet ever attaches, the system either declined to show the prompt
        // or showed it in its own window, and the host is no longer needed.
        Task { @MainActor in
            var sawSheet = false
            for second in 1...600 {
                try? await Task.sleep(for: .seconds(1))
                if window.attachedSheet != nil {
                    sawSheet = true
                } else if sawSheet || second >= 15 {
                    break
                }
            }
            window.orderOut(nil)
            if hostWindow === window { hostWindow = nil }
        }
    }
}
