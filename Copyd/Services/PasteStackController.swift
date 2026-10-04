import AppKit
import KeyboardShortcuts
import os
import SwiftData
import SwiftUI

/// Paste Stack: while it is on, every copy joins the stack and each ⌘V pastes the next clip.
///
/// ⌘V is seen by a listen-only session event tap, which needs Input Monitoring and can't hold or
/// change the key. So the clip the next ⌘V takes (the head) is put on the pasteboard ahead of
/// time: after the first copy, after each FIFO copy, and when a ⌘V finishes. Paste Stack posts no
/// keystrokes. The tap lives from `start()` to `stop()`; the stack ends when the last clip is
/// pasted, from the shortcut or the menu, or when a clip is picked in Copyd's own UI.
@MainActor
@Observable
final class PasteStackController {
    private(set) var isActive = false
    /// Clips still queued, the staged one included, shown in the HUD.
    private(set) var count = 0
    weak var appState: AppState?

    @ObservationIgnored private var stack = PasteStack(order: .fifo)
    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "PasteStack")
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var tapSource: CFRunLoopSource?
    @ObservationIgnored private var hud: NSPanel?
    /// A ⌘V went down with the head staged; it is popped on the V key-up or the fallback.
    @ObservationIgnored private var pendingPaste = false
    @ObservationIgnored private var fallback: Task<Void, Never>?
    /// `changeCount` right after the last staging write (or LIFO push that left the copy as head).
    @ObservationIgnored private var stagedChangeCount = 0

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
        guard CGPreflightListenEventAccess(), installTap() else {
            showInputMonitoringAlert()
            return
        }
        stack = PasteStack(order: .saved())
        count = 0
        isActive = true
        Self.log.notice("start order=\(self.stack.order.rawValue, privacy: .public)")
        showHUD()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        removeTap()
        pendingPaste = false
        fallback?.cancel()
        fallback = nil
        hud?.orderOut(nil)
        stack = PasteStack(order: .fifo)
        count = 0
    }

    /// Every clip the user copies. Ignored while the stack is off.
    func push(_ id: UUID) {
        guard isActive else { return }
        stage(stack.stagingAfterPush(id))
    }

    // MARK: - ⌘V, from the tap callback: only flags and scheduling here

    fileprivate func pasteKeyDown() {
        // Inside Copyd (Settings, the paywall, the panel) ⌘V pastes the staged clip and keeps the stack.
        Self.log.notice("⌘V down active=\(self.isActive) count=\(self.stack.count) appActive=\(NSApp.isActive) panel=\(self.appState?.panelController.isVisible == true)")
        guard isActive, !stack.isEmpty, !NSApp.isActive,
              appState?.panelController.isVisible != true else { return }
        pendingPaste = true
        fallback?.cancel()
        // The key-up is the normal trigger. This only covers a lost key-up (a tap paused by secure
        // input) so the stack isn't stuck; while V is still physically down, keep waiting (max 5 s).
        fallback = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            var waited = 1000
            while !Task.isCancelled, waited < 5000,
                  CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(PasteStack.pasteKeyCode)) {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 100
            }
            guard !Task.isCancelled else { return }
            self?.finishPaste()
        }
    }

    fileprivate func pasteKeyUp() {
        Self.log.notice("V up pending=\(self.pendingPaste)")
        guard pendingPaste else { return }
        Task { @MainActor [weak self] in self?.finishPaste() }
    }

    /// The app in front has read the staged head: drop it and stage the next, or end the stack.
    private func finishPaste() {
        guard isActive, pendingPaste else { return }
        pendingPaste = false
        fallback?.cancel()
        fallback = nil
        // The tap can't hold ⌘V and the monitor polls every 0.5 s, so a copy made just before ⌘V may
        // be what got pasted. Then the head was never pasted: keep it. The monitor captures that copy
        // and `push` re-stages (FIFO) or makes it the head (LIFO), after the capture so the skip flag
        // can't swallow it.
        let current = NSPasteboard.general.changeCount
        Self.log.notice("finish staged=\(self.stagedChangeCount) current=\(current)")
        guard PasteStack.shouldPop(stagedChangeCount: stagedChangeCount,
                                   currentChangeCount: current) else { return }
        // The one place a stack paste counts toward the review prompt.
        ReviewPrompter.recordPaste()
        stage(stack.stagingAfterPop())
    }

    /// Puts `id`'s clip on the pasteboard for the next ⌘V. nil with clips left means the head is
    /// already there; nil with none left ends the stack.
    private func stage(_ id: UUID?) {
        count = stack.count
        guard let id else {
            if stack.isEmpty { stop() } else { stagedChangeCount = NSPasteboard.general.changeCount }
            return
        }
        guard let appState, let context = appState.modelContainer?.mainContext else { return }
        let descriptor = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })
        guard let item = try? context.fetch(descriptor).first else {
            // Deleted since it was copied: skip it.
            return stage(stack.stagingAfterPop())
        }
        // Not a pick from Copyd's UI, so this write doesn't stop the stack.
        appState.clipboardMonitor.skipStagedChange()
        // The setting alone decides plain text: a Shift held while staging means nothing here.
        appState.pasteService.paste(
            item: item,
            asPlainText: UserDefaults.standard.bool(forKey: PasteService.alwaysPlainTextDefaultsKey),
            recordPaste: false
        )
        stagedChangeCount = NSPasteboard.general.changeCount
        Self.log.notice("staged count=\(self.stack.count) changeCount=\(self.stagedChangeCount)")
    }

    // MARK: - Event tap

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: pasteStackTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        tapSource = source
        return true
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

    /// macOS turns a tap off during secure input or after a slow callback.
    fileprivate func reenableTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func showInputMonitoringAlert() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Paste Stack needs Input Monitoring")
        alert.informativeText = String(localized: "To paste the next clip with ⌘V, Copyd has to see that key. Turn on Copyd in System Settings › Privacy & Security › Input Monitoring, then start Paste Stack again.")
        alert.addButton(withTitle: String(localized: "Open Input Monitoring Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Self.openInputMonitoringSettings()
    }

    /// Adds Copyd to the Input Monitoring list (the first time macOS also shows its own prompt) and opens it.
    static func openInputMonitoringSettings() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - HUD

    private func showHUD() {
        let panel = hud ?? Self.makeHUDPanel(PasteStackHUD(controller: self))
        Self.showAtTop(panel, size: NSSize(width: 560, height: 56))
        hud = panel
    }

    /// Orders a HUD panel in at the top center of the screen with the pointer.
    static func showAtTop(_ panel: NSPanel, size: NSSize) {
        guard let screen = PanelController.screen(containing: NSEvent.mouseLocation, in: NSScreen.screens)
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    /// Never takes focus and lets clicks through to whatever is underneath.
    static func makeHUDPanel(_ rootView: some View) -> NSPanel {
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
        let host = NSHostingView(rootView: rootView)
        // Keep the panel's fixed frame so the pill stays centered as its text changes width.
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
}

/// Runs on the main thread: the tap's source is on the main run loop. A listen-only tap only
/// observes, so whatever it returns, every key reaches the app in front untouched.
private func pasteStackTapCallback(
    _: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // The ⌘V Copyd posts after a pick is never the user's: it must not pop the stack.
    if let userInfo, !CopydSyntheticPaste.isMarked(event) {
        let controller = Unmanaged<PasteStackController>.fromOpaque(userInfo).takeUnretainedValue()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            MainActor.assumeIsolated { controller.reenableTap() }
        case .keyDown where PasteStack.isPasteKey(event):
            MainActor.assumeIsolated { controller.pasteKeyDown() }
        case .keyUp where event.getIntegerValueField(.keyboardEventKeycode) == PasteStack.pasteKeyCode:
            MainActor.assumeIsolated { controller.pasteKeyUp() }
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
        HUDPill {
            Text("Paste Stack · \(controller.count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.Brand.ink)
                .monospacedDigit()
            hint
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.Brand.ink2)
        }
    }

    /// Names the real stop shortcut, as the menu row does.
    private var hint: Text {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .togglePasteStack)?.description {
            Text("⌘V pastes next · \(shortcut) stops")
        } else {
            Text("⌘V pastes next")
        }
    }
}

/// The brand pill a HUD shows at the top of the screen: the Copyd mark, then `content`.
struct HUDPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            CopydMark(size: 18)
            content
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
