import AppKit
import SwiftUI
import SwiftData

/// Shows the first-run welcome tour in a standalone window.
/// The tour appears once (tracked via UserDefaults) and can be reopened
/// from Settings → General → "Show Welcome Tour".
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    static let completedDefaultsKey = "hasCompletedOnboarding"

    private var window: NSWindow?

    func showIfNeeded(appState: AppState, modelContainer: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: Self.completedDefaultsKey) else { return }
        show(appState: appState, modelContainer: modelContainer)
    }

    func show(appState: AppState, modelContainer: ModelContainer) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = OnboardingView { [weak self] in
            self?.finish()
        }
        .environment(appState)
        .modelContainer(modelContainer)

        let hosting = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.styleMask = [.titled, .closable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.standardWindowButton(.zoomButton)?.isHidden = true
        newWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
        // NOTE: keep isMovableByWindowBackground off — when enabled, clicks on the
        // KeyboardShortcuts recorder (non-opaque NSSearchField) get swallowed as
        // window drags and the field never receives focus.
        newWindow.isReleasedWhenClosed = false
        newWindow.setContentSize(NSSize(width: 560, height: 660))
        newWindow.delegate = self
        newWindow.center()

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedDefaultsKey)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window with ⌘W / the close button also counts as done,
        // so the tour never nags on subsequent launches.
        UserDefaults.standard.set(true, forKey: Self.completedDefaultsKey)
        window = nil

        Task { @MainActor in
            await PaywallWindowController.shared.showAfterOnboardingIfNeeded()
        }
    }
}
