import AppKit
import SwiftData
import SwiftUI

/// Paste Stack: while it is on, every copy joins the stack and each ⌘V pastes the next clip.
///
/// ⌘V is seen by a session event tap that exists only while the stack is on and holds at
/// least one clip. The tap never swallows or posts a key event: on ⌘V it puts the next clip
/// on the pasteboard through `PasteService` and returns the user's own ⌘V unchanged, so the
/// app in front pastes that clip. Copyd posts no keystrokes, so there is nothing of its own
/// for the tap to filter out. When the last clip goes, the stack ends and the tap is removed.
@MainActor
@Observable
final class PasteStackController {
    private(set) var isActive = false
    /// Clips still queued, shown in the HUD.
    private(set) var count = 0
    weak var appState: AppState?

    @ObservationIgnored private var stack = PasteStack(order: .fifo)
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var escMonitors: [Any] = []
    @ObservationIgnored private var hud: NSPanel?

    private static let escapeKeyCode: UInt16 = 53

    func toggle() {
        isActive ? stop() : start()
    }

    func start() {
        guard !isActive else { return }
        // Pasting from the history is part of the trial or unlock, like the panel.
        guard Entitlements.shared.checkHistoryAccess() else {
            PaywallWindowController.shared.show()
            return
        }
        // Catching ⌘V needs Accessibility. Find out now, not on the first ⌘V.
        guard let probe = makeTap() else {
            showAccessibilityAlert()
            return
        }
        CFMachPortInvalidate(probe)

        stack = PasteStack(order: .saved())
        count = 0
        isActive = true
        installEscMonitors()
        showHUD()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        removeTap()
        escMonitors.forEach(NSEvent.removeMonitor)
        escMonitors = []
        hud?.orderOut(nil)
        stack = PasteStack(order: .fifo)
        count = 0
    }

    /// Every clip the user copies. Ignored while the stack is off.
    func push(_ id: UUID) {
        guard isActive else { return }
        stack.push(id)
        count = stack.count
        if tap == nil { installTap() }
    }

    /// The user pressed ⌘V: put the next clip on the pasteboard before the front app reads it.
    fileprivate func pasteNext() {
        // ⌘V in Copyd's own search field pastes as usual and keeps the stack.
        guard isActive, let appState, !appState.panelController.isVisible,
              let context = appState.modelContainer?.mainContext else { return }
        while let id = stack.popNext() {
            // A clip deleted since it was copied is skipped.
            let descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
            guard let item = try? context.fetch(descriptor).first else { continue }
            appState.clipboardMonitor.skipNextChange()
            appState.pasteService.paste(item: item)
            break
        }
        count = stack.count
        // End on the next turn, after this ⌘V has been handed back to the system.
        if stack.isEmpty {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    // MARK: - Event tap

    private func makeTap() -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: pasteStackTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func installTap() {
        guard let port = makeTap() else {
            // Accessibility was turned off after the stack started.
            stop()
            showAccessibilityAlert()
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        tapSource = source
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
    }

    /// macOS turns a tap off when a callback runs long or during secure input.
    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Paste Stack needs Accessibility")
        alert.informativeText = String(localized: "To paste the next clip with ⌘V, Copyd has to see that key. Turn on Copyd in System Settings › Privacy & Security › Accessibility, then start Paste Stack again.")
        alert.addButton(withTitle: String(localized: "Open Accessibility Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Adds Copyd to the Accessibility list; the first time macOS may also show its own prompt.
        _ = CGRequestPostEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Esc

    private func installEscMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.escapeKeyCode else { return }
            Task { @MainActor in self?.stop() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isEscape = event.keyCode == Self.escapeKeyCode
            MainActor.assumeIsolated { [weak self] in
                // The history panel uses Esc to step back; leave it the key there.
                guard isEscape, let self, self.appState?.panelController.isVisible != true else { return }
                self.stop()
            }
            return event
        }
        escMonitors = [global, local].compactMap { $0 }
    }

    // MARK: - HUD

    private func showHUD() {
        let size = NSSize(width: 560, height: 56)
        guard let screen = PanelController.screen(containing: NSEvent.mouseLocation, in: NSScreen.screens)
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height,
                           width: size.width, height: size.height)

        let panel = hud ?? makeHUDPanel()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        hud = panel
    }

    /// Never takes focus and lets clicks through to whatever is underneath.
    private func makeHUDPanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Copyd is rarely the active app; the HUD must stay up while the user works elsewhere.
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: PasteStackHUD(controller: self))
        // Keep the panel's fixed frame so the pill stays centered as the count changes width.
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

/// Runs on the main thread: the tap's source is on the main run loop.
/// Returning the event unchanged lets every key, ⌘V included, reach the app in front.
private func pasteStackTapCallback(
    _: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let controller = Unmanaged<PasteStackController>.fromOpaque(userInfo).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            MainActor.assumeIsolated { controller.reenableTap() }
        case .keyDown where PasteStack.isPasteKey(event):
            MainActor.assumeIsolated { controller.pasteNext() }
        default:
            break
        }
    }
    return Unmanaged.passUnretained(event)
}

/// The brand pill at the top of the screen while the stack is on.
private struct PasteStackHUD: View {
    let controller: PasteStackController

    var body: some View {
        HStack(spacing: 8) {
            CopydMark(size: 18)
            Text("Paste Stack · \(controller.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.Brand.ink)
                .monospacedDigit()
            Text("⌘V pastes next · esc stops")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Brand.ink2)
        }
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .frame(height: 32)
        .background(DesignTokens.Brand.card, in: Capsule())
        .overlay(Capsule().strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
