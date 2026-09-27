#if APPSTORE
import AppKit
import SwiftUI

/// Presents the trial and unlock screen in a standalone window (Mac App Store build only).
@MainActor
final class PaywallWindowController: NSObject, NSWindowDelegate {
    static let shared = PaywallWindowController()

    /// Set once the trial offer has followed the welcome tour, so it never repeats there.
    static let shownAfterOnboardingKey = "paywall.shownAfterOnboarding"

    private let model = PaywallModel()
    private var window: NSWindow?

    /// - Parameter restore: Also runs Restore Purchases, for the menu bar item.
    func show(restore: Bool = false) {
        let entitlements = Entitlements.shared
        entitlements.reevaluate()
        if entitlements.trialProduct == nil || entitlements.lifetimeProduct == nil {
            Task { await entitlements.loadProducts() }
        }

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            model.reset()
            let hosting = NSHostingController(rootView: PaywallView(
                model: model,
                onClose: { [weak self] in self?.window?.close() },
                onHeightChange: { [weak self] height in self?.resize(toHeight: height) }
            ))
            // The window is sized by hand. Letting it follow the hosting controller's
            // preferred size made starting the trial (two content changes in a row)
            // loop in AppKit's constraint pass until it threw "more Update Constraints
            // in Window passes than there are views", which terminated the app.
            hosting.sizingOptions = []

            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = String(localized: "Unlock Clipbara")
            newWindow.styleMask = [.titled, .closable, .fullSizeContentView]
            newWindow.titlebarAppearsTransparent = true
            newWindow.titleVisibility = .hidden
            newWindow.standardWindowButton(.zoomButton)?.isHidden = true
            newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.setContentSize(NSSize(width: 440, height: max(hosting.view.fittingSize.height, 200)))
            newWindow.center()

            window = newWindow
            newWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        if restore {
            model.restore()
        }
    }

    /// Offers the trial once, right after the welcome tour closes, to new users
    /// who have neither started it nor unlocked. Anyone else is left alone.
    func showAfterOnboardingIfNeeded() async {
        guard !UserDefaults.standard.bool(forKey: Self.shownAfterOnboardingKey) else { return }
        await Entitlements.shared.refresh()
        guard Entitlements.shared.state == .trialNotStarted else { return }
        UserDefaults.standard.set(true, forKey: Self.shownAfterOnboardingKey)
        show()
    }

    /// Resizes on the next turn, outside the layout pass that reported the height,
    /// keeping the window's top edge in place.
    private func resize(toHeight height: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, height > 0 else { return }
            let current = window.contentView?.frame.height ?? 0
            guard abs(current - height) > 0.5 else { return }
            var frame = window.frame
            let newFrame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 440, height: height))
            frame.origin.y += frame.height - newFrame.height
            frame.size = newFrame.size
            window.setFrame(frame, display: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        model.reset()
    }
}
#endif
