import AppKit
import SwiftUI
import SwiftData

@MainActor
@Observable
final class PanelController {
    private var panel: CopydPanel?
    /// The panel's SwiftUI content. Slid inside the fixed panel frame so the
    /// window itself never has to travel off screen to animate.
    private var contentHost: NSView?
    /// The screen the panel was opened on. `panel.screen` is unreliable while
    /// the panel sits flush against a screen edge next to another display.
    private var presentedScreen: NSScreen?
    private var quickLookPanel: ClipboardQuickLookPanel?
    private var quickLookItem: ClipboardItem?
    private var quickLookZoom: ImageZoomController?
    private(set) var isVisible: Bool = false
    private var clickMonitor: Any?
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    private var wheelTranslator = WheelScrollTranslation.Translator()
    private var keyMonitor: Any?
    private var flagsMonitor: Any?
    /// The app in front when the panel opened. It gets focus back when the panel hides.
    private var focusReturnApp: NSRunningApplication?
    var onPanelWillHide: (() -> Void)?
    weak var appState: AppState?

    private let baseHeight = PanelGeometry.height

    // MARK: - Screen Selection

    /// Returns the screen that contains `point`, if any.
    ///
    /// Kept static and dependency free so the multi display placement rules can
    /// be exercised without attaching real hardware.
    static func screen(containing point: NSPoint, in screens: [NSScreen]) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    /// The display the user is actually working on.
    ///
    /// `NSScreen.main` resolves to the screen owning the key window, not the
    /// screen the user is looking at. Copyd is a menu bar app and is never
    /// the active app when the hotkey fires, so `NSScreen.main` can point at
    /// whichever display last held focus and the panel slides in on the wrong
    /// screen. The pointer location matches the user's intent, so prefer it and
    /// fall back to `NSScreen.main` only when the pointer is off screen.
    private var activeScreen: NSScreen {
        Self.screen(containing: NSEvent.mouseLocation, in: NSScreen.screens)
            ?? NSScreen.main
            ?? NSScreen.screens.first!
    }

    func toggle(modelContainer: ModelContainer, appState: AppState) {
        if isVisible {
            hidePanel()
        } else {
            showPanel(modelContainer: modelContainer, appState: appState)
        }
    }

    /// Builds the panel and renders its first frame off screen so the first
    /// hotkey press only has to animate. Called shortly after launch.
    func prewarm(modelContainer: ModelContainer, appState: AppState) {
        guard panel == nil else { return }
        self.appState = appState

        // Build the warm panel at its real on screen position. Parking it below
        // the screen would hand it to a display stacked underneath before the
        // first hotkey press ever happens. It stays invisible via `alphaValue`.
        let screenFrame = activeScreen.visibleFrame
        let frame = panelFrame(in: screenFrame, y: screenFrame.origin.y)

        let warm = CopydPanel(contentRect: frame)
        warm.alphaValue = 0
        warm.contentView = makeContentView(modelContainer: modelContainer, appState: appState, size: frame.size)
        warm.orderFrontRegardless()
        warm.contentView?.layoutSubtreeIfNeeded()
        warm.displayIfNeeded()
        warm.orderOut(nil)
        warm.alphaValue = 1
        panel = warm
    }

    func showPanel(modelContainer: ModelContainer, appState: AppState) {
        guard !isVisible else { return }
        self.appState = appState

        let screen = activeScreen
        let screenFrame = screen.visibleFrame
        let endFrame = panelFrame(in: screenFrame, y: screenFrame.origin.y)
        presentedScreen = screen
        focusReturnApp = NSWorkspace.shared.frontmostApplication

        if panel == nil {
            panel = CopydPanel(contentRect: endFrame)
            panel?.contentView = makeContentView(
                modelContainer: modelContainer,
                appState: appState,
                size: endFrame.size
            )
        } else {
            panel?.setFrame(endFrame, display: false)
        }

        // The panel frame stays put; the content starts one panel height below
        // the window and rides up into it. Moving the window itself would push
        // it onto a display stacked underneath, which is how the panel used to
        // end up on the wrong screen.
        contentHost?.frame.origin.y = -endFrame.height
        panel?.alphaValue = 1

        // The window shadow is derived from the content alpha. While the
        // content is only partly inside the frame the shadow would outline
        // empty space, so drop it for the duration of the slide.
        panel?.hasShadow = false

        panel?.orderFrontRegardless()
        panel?.makeKey()
        panel?.makeFirstResponder(nil)

        // Ordering a window in is not instant: the window server needs a
        // composited frame before anything reaches the screen. Starting the
        // slide in this same turn meant the easeOut curve was already most of
        // the way through by the time the panel actually appeared, so the
        // content popped in instead of riding up. Push the parked first frame
        // out now, then start the slide on the next main actor turn so the
        // whole curve happens on screen. `hidePanel` never had this problem
        // because its window is already visible when it animates.
        panel?.contentView?.displayIfNeeded()
        CATransaction.flush()

        Task { @MainActor [weak self] in
            guard let self, let contentHost = self.contentHost else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                var target = contentHost.frame
                target.origin.y = 0
                contentHost.animator().frame = target
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    self?.panel?.hasShadow = true
                    self?.panel?.invalidateShadow()
                }
            })
        }

        isVisible = true
        appState.markPanelPresented()
        installClickMonitor()
        installMouseMonitor()
        installScrollMonitor()
        installKeyMonitor()
        appState.isCommandHeld = NSEvent.modifierFlags
            .intersection([.command, .option, .control, .shift]) == .command
        installFlagsMonitor()
    }

    func restoreKeyboardNavigationFocus() {
        guard isVisible, let panel else { return }
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nil)
    }

    func hidePanel() {
        guard isVisible, let panel else { return }
        panel.makeFirstResponder(nil)
        onPanelWillHide?()
        hideQuickLook()

        let panelHeight = panel.frame.height

        removeClickMonitor()
        removeMouseMonitor()
        removeScrollMonitor()
        removeKeyMonitor()
        removeFlagsMonitor()
        appState?.isCommandHeld = false
        appState?.firstVisibleIndex = 0

        panel.hasShadow = false

        NSAnimationContext.runAnimationGroup({ [contentHost] context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if let contentHost {
                var target = contentHost.frame
                target.origin.y = -panelHeight
                contentHost.animator().frame = target
            }
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                panel.orderOut(nil)
                self?.giveFocusBack()
                panel.hasShadow = true
                self?.contentHost?.frame.origin.y = 0
                self?.presentedScreen = nil
                self?.isVisible = false
            }
        })
    }

    /// The panel took the key window from this app without deactivating it, and ordering the panel
    /// out leaves that app in front with no key window: no caret, and direct paste's ⌘V lands nowhere.
    /// Re-activating it brings its key window and text field back. Runs right after `orderOut`, so it
    /// happens before AutoPaster, which waits for the panel to lose key, posts ⌘V.
    private func giveFocusBack() {
        let app = focusReturnApp
        focusReturnApp = nil
        guard let app, !app.isTerminated,
              AutoPastePolicy.restoresFocus(
                target: app.processIdentifier,
                frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                own: ProcessInfo.processInfo.processIdentifier,
                copydInFront: NSApp.isActive || NSApp.keyWindow != nil
              ) else { return }
        _ = app.activate()
    }

    // MARK: - Click Monitor (dismiss on outside click)

    private func installClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp]
        ) { [weak self] event in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                if event.type == .leftMouseUp, self.appState?.draggedClipboardItemID != nil {
                    self.appState?.finishClipboardDrag()
                    return
                }
                if let panel = self.panel,
                   !panel.frame.contains(NSEvent.mouseLocation) {
                    self.hidePanel()
                }
            }
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    // MARK: - Mouse Monitor (release search focus before card clicks)

    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                if event.type == .leftMouseUp, self.appState?.draggedClipboardItemID != nil {
                    self.appState?.finishClipboardDrag()
                } else {
                    self.releaseTextFocusIfNeeded(for: event)
                }
            }
            return event
        }
    }

    private func removeMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    // MARK: - Scroll Monitor (mouse wheel over the sideways card rows)

    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let handled: Bool = MainActor.assumeIsolated { [weak self] in
                self?.translateWheelToHorizontalScroll(event) ?? false
            }
            return handled ? nil : event
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    /// Re-sends a mouse wheel as horizontal movement over a sideways card row.
    private func translateWheelToHorizontalScroll(_ event: NSEvent) -> Bool {
        guard isVisible,
              let window = event.window,
              window === panel || window === quickLookPanel,
              let scrollView = horizontalScrollView(under: event, in: window) else { return false }

        // Cmd/Option + wheel zooms a Quick Look image; leave it to the image view.
        if scrollView is ZoomingImageScrollView,
           !event.modifierFlags.intersection([.command, .option]).isEmpty {
            return false
        }

        let clip = scrollView.contentView.bounds.size
        let document = scrollView.documentView?.frame.size ?? .zero
        let input = WheelScrollTranslation.Input(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            phase: WheelScrollTranslation.phase(of: event),
            canScrollHorizontally: document.width - clip.width > 0.5,
            canScrollVertically: document.height - clip.height > 0.5
        )
        guard wheelTranslator.shouldTranslate(input) else { return false }

        guard let horizontalEvent = WheelScrollTranslation.horizontalCopy(of: event) else { return false }
        scrollView.scrollWheel(with: horizontalEvent)
        return true
    }

    private func horizontalScrollView(under event: NSEvent, in window: NSWindow) -> NSScrollView? {
        guard let contentView = window.contentView else { return nil }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(point) else { return nil }

        var view: NSView? = hit
        while let current = view {
            if let scrollView = current as? NSScrollView {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }

    private func releaseTextFocusIfNeeded(for event: NSEvent) {
        guard isVisible, let panel else { return }

        let screenPoint = NSEvent.mouseLocation
        guard panel.frame.contains(screenPoint) else { return }

        if isTextInputFocused(in: panel),
           !eventHitsTextInput(event, in: panel) {
            panel.makeFirstResponder(nil)
        }
    }

    private func isTextInputFocused(in panel: NSPanel) -> Bool {
        guard let firstResponder = panel.firstResponder else { return false }
        return firstResponder is NSTextView || firstResponder is NSTextField
    }

    private func eventHitsTextInput(_ event: NSEvent, in panel: NSPanel) -> Bool {
        guard let contentView = panel.contentView else { return false }
        let locationInContent = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(locationInContent) else { return false }

        var view: NSView? = hitView
        while let current = view {
            if current is NSTextField || current is NSTextView {
                return true
            }
            view = current.superview
        }
        return false
    }

    /// Shared by mouse tabs and Cmd+number. Clear the old navigation cache
    /// synchronously so a fast Return cannot paste an item from the old tab
    /// while SwiftUI is still rendering the new one.
    func selectTab(_ tab: PanelTab) {
        guard let appState, isVisible, appState.selectedTab != tab else { return }
        if quickLookPanel != nil { hideQuickLook() }
        appState.selectForPreview(nil)
        appState.searchState.selectedIndex = nil
        appState.searchState.multiSelection.clear()
        appState.currentFilteredItems = []
        appState.selectedTab = tab
    }

    // MARK: - Key Monitor (tab shortcuts, arrow keys, space, esc, return)

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let eventWindowNumber = event.windowNumber
            let shift = event.modifierFlags.intersection([.command, .option, .control, .shift]) == .shift
            let handled: Bool = MainActor.assumeIsolated { [weak self] in
                guard let self, self.isVisible else { return false }

                // Pass through key events that target other windows (e.g. the rename
                // alert), so their text fields receive Return/Escape as expected.
                if eventWindowNumber != 0,
                   eventWindowNumber != self.panel?.windowNumber,
                   eventWindowNumber != self.quickLookPanel?.windowNumber {
                    return false
                }

                // Never navigate behind a create/rename/delete sheet or modal.
                guard self.panel?.attachedSheet == nil,
                      self.quickLookPanel?.attachedSheet == nil,
                      NSApp.modalWindow == nil else { return false }

                // Command-number paste: before the Quick Look branch and the
                // search-field pass-through. Consumed even when no card exists.
                if let match = QuickPasteShortcut.match(keyCode: keyCode, modifiers: event.modifierFlags) {
                    self.appState?.quickPaste(number: match.number)
                    return true
                }

                // Handle tab shortcuts before the search-field pass-through.
                // Missing tabs are a no-op, not a shortcut for the frontmost app.
                if let index = PanelTabShortcut.index(keyCode: keyCode, modifiers: event.modifierFlags) {
                    if let appState = self.appState,
                       let tab = PanelTabShortcut.target(at: index, pinboardIDs: appState.orderedPinboardIDs) {
                        self.selectTab(tab)
                    }
                    return true
                }

                if self.quickLookPanel != nil {
                    if let zoom = self.quickLookZoom,
                       let action = ImageZoomController.action(keyCode: keyCode, modifiers: event.modifierFlags) {
                        zoom.perform(action)
                        return true
                    }
                    return self.processKey(keyCode, shift: shift)
                }

                // Check if a text field is focused (search bar) - let it handle the event
                if let firstResponder = self.panel?.firstResponder,
                   firstResponder is NSTextView || firstResponder is NSTextField {
                    // Still handle Escape to close search/panel
                    if keyCode == 53 {
                        return self.processKey(keyCode, shift: shift)
                    }
                    return false
                }

                return self.processKey(keyCode, shift: shift)
            }
            return handled ? nil : event
        }
    }

    private func processKey(_ keyCode: UInt16, shift: Bool) -> Bool {
        guard let appState, isVisible else { return false }
        let items = appState.currentFilteredItems
        let maxIndex = items.count - 1

        // Quick Look toggle (user-configurable key, default Space)
        if keyCode == QuickLookKeySetting.keyCode {
            if quickLookPanel != nil {
                hideQuickLook()
                return true
            }
            if appState.previewItem != nil {
                withAnimation(.easeOut(duration: 0.2)) {
                    appState.selectForPreview(nil)
                }
                return true
            }
            if let idx = appState.searchState.selectedIndex, idx < items.count {
                let item = items[idx]
                showQuickLook(item: item)
                return true
            }
            return false
        }

        switch keyCode {
        case 53: // Escape
            if quickLookPanel != nil {
                hideQuickLook()
                return true
            }
            if appState.previewItem != nil {
                appState.searchState.selectedIndex = nil
                appState.selectForPreview(nil)
                return true
            }
            if !appState.searchState.multiSelection.ids.isEmpty {
                appState.searchState.multiSelection.clear()
                return true
            }
            if appState.searchState.isActive {
                appState.searchState.reset()
                return true
            }
            if appState.selectedTab != .history {
                selectTab(.history)
                return true
            }
            appState.hidePanel()
            return true

        case 123, 124: // Left, Right arrow. With Shift they extend the multi-selection.
            let step = keyCode == 123 ? -1 : 1
            if shift, let focus = appState.searchState.selectedIndex {
                appState.extendSelection(to: max(0, min(focus + step, maxIndex)))
            } else {
                appState.searchState.multiSelection.clear()
                appState.searchState.moveSelection(by: step, maxIndex: maxIndex)
            }
            if let idx = appState.searchState.selectedIndex, idx < items.count {
                if quickLookPanel != nil {
                    updateQuickLook(for: items[idx])
                } else if appState.previewItem != nil {
                    appState.previewItem = items[idx]
                }
            }
            return true

        case 36: // Return - paste
            if let item = quickLookItem {
                appState.clipboardMonitor.skipNextChange()
                appState.pasteService.paste(item: item)
                appState.hidePanel()
                return true
            }

            // Return and Shift-Return both paste the joined text as plain text.
            if appState.multiSelectedItems.count >= 2 {
                appState.pasteSelection()
                return true
            }

            guard let idx = appState.searchState.selectedIndex,
                  idx < items.count else { return false }
            let item = items[idx]
            appState.clipboardMonitor.skipNextChange()
            appState.pasteService.paste(item: item)
            appState.hidePanel()
            return true

        default:
            return false
        }
    }

    // MARK: - Clipboard Quick Look

    private func showQuickLook(item: ClipboardItem) {
        guard let appState else { return }

        appState.selectForPreview(nil)
        quickLookItem = item

        let screen = self.panel?.screen ?? activeScreen
        let screenFrame = screen.visibleFrame

        let panel: ClipboardQuickLookPanel
        if let existing = quickLookPanel {
            panel = existing
            panel.setFrame(screenFrame, display: false)
        } else {
            panel = ClipboardQuickLookPanel(contentRect: screenFrame)
            quickLookPanel = panel
        }

        let zoom = ImageZoomController()
        quickLookZoom = zoom

        panel.contentView = NSHostingView(
            rootView: ClipboardQuickLookView(
                item: item,
                shelfHeight: baseHeight,
                zoom: zoom,
                onClose: { [weak self] in
                    self?.hideQuickLook()
                },
                onPaste: { [weak self, weak appState] in
                    guard let self, let appState else { return }
                    appState.clipboardMonitor.skipNextChange()
                    appState.pasteService.paste(item: item)
                    self.hidePanel()
                }
            )
            .environment(appState)
        )

        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func updateQuickLook(for item: ClipboardItem) {
        guard quickLookPanel != nil else { return }
        showQuickLook(item: item)
    }

    private func hideQuickLook() {
        quickLookPanel?.orderOut(nil)
        quickLookPanel = nil
        quickLookItem = nil
        quickLookZoom = nil
        panel?.makeKey()
    }

    private func installFlagsMonitor() {
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let flags = event.modifierFlags
            MainActor.assumeIsolated { [weak self] in
                guard let self, self.isVisible else { return }
                self.appState?.isCommandHeld =
                    flags.intersection([.command, .option, .control, .shift]) == .command
            }
            return event
        }
    }

    private func removeFlagsMonitor() {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Wraps the SwiftUI content in a plain container so it can be offset
    /// inside the panel. Anything pushed outside the panel frame is clipped by
    /// the window surface, which is what makes the slide read as a reveal.
    private func makeContentView(
        modelContainer: ModelContainer,
        appState: AppState,
        size: NSSize
    ) -> NSView {
        let host = NSHostingView(
            rootView: HistoryPanelView()
                .environment(appState)
                .modelContainer(modelContainer)
        )
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        container.addSubview(host)

        contentHost = host
        return container
    }

    /// Full-width shelf frame; `y` lets the slide animation park it lower.
    private func panelFrame(in screenFrame: NSRect, y: CGFloat) -> NSRect {
        var frame = PanelGeometry.frame(visibleFrame: screenFrame, height: baseHeight)
        frame.origin.y = y
        return frame
    }
}
