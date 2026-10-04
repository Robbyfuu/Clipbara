import AppKit
import OSLog
import SwiftUI

/// "Paste directly into the app": after a pick in Copyd's UI, posts ⌘V to the app the user was in.
///
/// Every pick goes through `ClipboardMonitor.skipNextChange`, whose `onPick` calls `pasteIntoFrontApp`
/// right before the clip is written. The ⌘V itself is posted later, once the panel is gone.
/// Posting keyboard events needs Accessibility.
@MainActor
final class AutoPaster {
    nonisolated static let enabledDefaultsKey = "autoPasteOnPick"
    private static let promptedDefaultsKey = "autoPastePrompted"
    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "AutoPaste")

    /// The "Paste directly into the app" setting, on by default.
    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) as? Bool ?? true }
    /// Copyd may post keyboard events (Privacy & Security › Accessibility).
    var hasAccess: Bool { CGPreflightPostEventAccess() }

    private var pasteTask: Task<Void, Never>?
    private var hint: NSPanel?
    private var hintTask: Task<Void, Never>?
    /// The last app other than Copyd to become active: where a pick from the menu bar list pastes.
    private var previousApp: NSRunningApplication?

    init() {
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            previousApp = front
        }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .processIdentifier, pid != own else { return }
            MainActor.assumeIsolated {
                self?.previousApp = NSRunningApplication(processIdentifier: pid)
            }
        }
    }

    /// Called for every pick, just before the clip is written. Does nothing with the setting off.
    func pasteIntoFrontApp() {
        guard isEnabled else { return }
        pasteTask?.cancel()
        pasteTask = Task { @MainActor [weak self] in
            // The panel is non-activating, yet it holds keyboard focus until it is ordered out at the end
            // of its 0.2 s slide; a ⌘V posted before that would land in the panel. Wait for it (max 1 s).
            var waited = 0
            while NSApp.keyWindow != nil, waited < 1000, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 10
            }
            // Let the pasteboard write settle, then wait for the app the user was in to be frontmost
            // (the menu bar path hands focus back asynchronously). Max 500 ms, otherwise no paste.
            try? await Task.sleep(for: .milliseconds(50))
            waited = 0
            while !AutoPastePolicy.focusReady(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                              previous: self?.previousApp?.processIdentifier),
                  waited < 500, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                waited += 20
            }
            guard !Task.isCancelled,
                  AutoPastePolicy.focusReady(frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                                             previous: self?.previousApp?.processIdentifier)
            else { return }
            self?.finishPick()
        }
    }

    /// The menu bar list makes Copyd the active app, so ⌘V would land in Copyd. With the setting on,
    /// hand focus back to the app the user was in, which also closes the list.
    func returnFocusFromMenuBar() {
        guard isEnabled, !titledCopydWindowVisible, let previousApp, !previousApp.isTerminated else { return }
        _ = previousApp.activate(options: [])
    }

    /// The settings button: adds Copyd to the Accessibility list (macOS asks the first time) and opens it.
    func openAccessibilitySettings() {
        UserDefaults.standard.set(true, forKey: Self.promptedDefaultsKey)
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Settings or Paywall is open: the user is working in Copyd, so ⌘V would land there.
    private var titledCopydWindowVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
    }

    private var hintShown = false

    private func finishPick() {
        let defaults = UserDefaults.standard
        let action = AutoPastePolicy.decide(
            enabled: isEnabled,
            hasAccess: hasAccess,
            copydIsActive: NSApp.isActive || NSApp.keyWindow != nil || titledCopydWindowVisible,
            alreadyPrompted: defaults.bool(forKey: Self.promptedDefaultsKey)
        )
        Self.log.notice("pick action=\(String(describing: action), privacy: .public)")
        switch action {
        case .paste:
            postCommandV()
        case .requestAccessAndHint:
            // Once ever: adds Copyd to Privacy & Security › Accessibility and shows macOS's own prompt.
            defaults.set(true, forKey: Self.promptedDefaultsKey)
            _ = CGRequestPostEventAccess()
            hintShown = true
            showHint()
        case .hintOnly:
            // Once per launch: repeating it on every pick is noise.
            guard !hintShown else { break }
            hintShown = true
            showHint()
        case .none:
            break
        }
    }

    /// Plain ⌘V, tagged so Paste Stack's tap ignores it. No ⇧, whatever keys are still held.
    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: CGKeyCode(PasteStack.pasteKeyCode),
                                      keyDown: keyDown) else { return }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: CopydSyntheticPaste.marker)
            event.post(tap: .cghidEventTap)
        }
    }

    /// The panel is already closed, so the hint shows at the top of the screen, like Paste Stack's HUD.
    private func showHint() {
        hintTask?.cancel()
        let panel = hint ?? PasteStackController.makeHUDPanel(HUDPill {
            Text("Allow Copyd in Accessibility to paste directly. For now, press ⌘V.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.Brand.ink)
        })
        PasteStackController.showAtTop(panel, size: NSSize(width: 720, height: 56))
        hint = panel
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.hint?.orderOut(nil)
        }
    }
}
