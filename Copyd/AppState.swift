import SwiftUI
import SwiftData
import KeyboardShortcuts

struct PanelToast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let systemImage: String
}

@MainActor
@Observable
final class AppState {
    /// The one app-wide instance. Owned here rather than by SwiftUI state so it can
    /// never be recreated behind the hotkey and clipboard timer that point at it.
    static let shared = AppState()

    let clipboardMonitor = ClipboardMonitor()
    let pasteService = PasteService()
    let panelController = PanelController()
    let pasteStack = PasteStackController()
    let autoPaster = AutoPaster()
    let searchState = SearchState()

    var selectedTab: PanelTab = .history
    /// Published by NavigationBarView so shortcuts follow its exact display order.
    var orderedPinboardIDs: [UUID] = []
    var previewItem: ClipboardItem?
    var panelToast: PanelToast?
    var panelPresentationID = 0
    var draggedClipboardItemID: UUID?
    var firstVisibleIndex: Int = 0
    var isCommandHeld: Bool = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    private(set) var modelContainer: ModelContainer?

    /// Cached filtered items for keyboard navigation (updated by CardGridView)
    var currentFilteredItems: [ClipboardItem] = []
    /// Debounced search text that produced `currentFilteredItems`; quick paste is ignored while it lags the field.
    var currentFilteredQuery: String = ""

    private(set) var cloudSync: CloudSyncEngine?

    @ObservationIgnored private var hasStarted = false

    func start(modelContext: ModelContext, modelContainer: ModelContainer) {
        // App.init may run more than once; start the monitor and hotkeys only once.
        guard !hasStarted else { return }
        hasStarted = true
        self.modelContainer = modelContainer
        clipboardMonitor.start(modelContext: modelContext)
        PasteService.removeFilesOnDelete(in: modelContext)
        PasteService.removeOrphanFiles(in: modelContainer)
        PasteEvent.removeWithClips(in: modelContext)
        pasteStack.appState = self
        clipboardMonitor.onCapture = { [weak self] id in
            self?.pasteStack.push(id)
        }
        // Every pick in Copyd (panel, pinboard, menu bar, multi-paste, ⌘1–9) comes through here, right
        // before the clip is written. It ends Paste Stack, then pastes into the app the user was in once
        // the write is done and the panel is gone, and records which app the clips went into.
        clipboardMonitor.onPick = { [weak self] ids in
            self?.pasteStack.stop()
            self?.autoPaster.pasteIntoFrontApp()
            self?.recordPick(of: ids)
        }
        ReviewPrompter.noteLaunch()
        Entitlements.shared.start()
        panelController.onPanelWillHide = { [weak self] in
            self?.searchState.reset()
            self?.previewItem = nil
            ReviewPrompter.panelWillHide { [weak self] in
                self?.panelController.isVisible ?? false
            }
        }
        setupHotkey()

        let engine = CloudSyncEngine(container: modelContainer) { [weak self] in
            self?.clipboardMonitor.refreshLatestItems()
        }
        cloudSync = engine
        if UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) {
            engine.start()
        }

        // Render the panel once off screen so the first hotkey press is instant.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let container = self.modelContainer else { return }
            self.panelController.prewarm(modelContainer: container, appState: self)
        }
    }

    /// Paste history for suggestions. Whether the pick pastes directly or only copies, the clips go into the app the
    /// panel opened over, or for the menu bar list the app the user was in. Nothing when that app is Copyd.
    private func recordPick(of ids: [UUID]) {
        let app = panelController.isVisible ? panelController.focusReturnApp : autoPaster.menuBarTarget
        guard !ids.isEmpty, let bundleID = app?.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier,
              let context = modelContainer?.mainContext else { return }
        PasteEvent.record(ids, app: bundleID, in: context)
    }

    func togglePanel() {
        guard let container = modelContainer else { return }
        // Without an active trial or unlock, offer it instead of the history.
        // Clipboard capture keeps running, so nothing is lost in the meantime.
        if !panelController.isVisible, !Entitlements.shared.checkHistoryAccess() {
            PaywallWindowController.shared.show()
            return
        }
        if !panelController.isVisible { cloudSync?.fetchIfStale() }
        panelController.toggle(modelContainer: container, appState: self)
    }

    func markPanelPresented() {
        panelPresentationID += 1
    }

    func selectForPreview(_ item: ClipboardItem?) {
        previewItem = item
    }

    func showToast(_ message: String, systemImage: String = "checkmark.circle.fill") {
        toastTask?.cancel()
        panelToast = PanelToast(message: message, systemImage: systemImage)
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard !Task.isCancelled else { return }
            panelToast = nil
        }
    }

    /// Shared paste path for panel and pinboard cards.
    /// - Parameter asPlainText: `nil` resolves from the setting combined with the Shift modifier.
    func paste(_ item: ClipboardItem, asPlainText: Bool? = nil) {
        clipboardMonitor.skipNextChange(picking: [item.id])
        pasteService.paste(item: item, asPlainText: asPlainText)
        hidePanel()
    }

    /// ⌘-click: adds or removes a card from the multi-selection.
    func toggleSelection(at index: Int) {
        searchState.selectedIndex = searchState.multiSelection.toggle(
            index, focus: searchState.selectedIndex, in: currentFilteredItems.map(\.id))
    }

    /// ⇧-click and ⇧-arrows: selects the range up to `index`.
    func extendSelection(to index: Int) {
        searchState.selectedIndex = searchState.multiSelection.extend(
            to: index, focus: searchState.selectedIndex, in: currentFilteredItems.map(\.id))
    }

    /// The multi-selection's cards on the current tab, in the order they were picked.
    var multiSelectedItems: [ClipboardItem] {
        searchState.multiSelection.items(in: currentFilteredItems)
    }

    /// Pastes the multi-selection's text joined by the saved separator, always as plain text.
    /// Does nothing when none of it is text.
    func pasteSelection() {
        let items = multiSelectedItems
        guard items.count >= 2, let joined = MultiPaste.join(items, separator: .saved()) else {
            NSSound.beep()
            return
        }
        ReviewPrompter.recordPaste()
        // One event per joined clip: images and files left out of the text don't count.
        clipboardMonitor.skipNextChange(picking: items.filter { MultiPaste.text(of: $0) != nil }.map(\.id))
        pasteService.pastePlainText(joined.text)
        hidePanel()
    }

    /// Command-number: paste the Nth visible card. `paste` already skips the
    /// monitor's next change and hides the panel. Live Shift decides plain text
    /// exactly as it does for Return. No-op when no card is there.
    func quickPaste(number: Int) {
        if selectedTab == .history, searchState.searchText != currentFilteredQuery { return }
        guard let index = QuickPasteShortcut.itemIndex(
            number: number,
            firstVisibleIndex: max(firstVisibleIndex, 0),
            itemCount: currentFilteredItems.count
        ), currentFilteredItems.indices.contains(index) else { return }
        paste(currentFilteredItems[index], asPlainText: nil)
    }

    func hidePanel() {
        previewItem = nil
        panelToast = nil
        toastTask?.cancel()
        draggedClipboardItemID = nil
        searchState.reset()
        selectedTab = .history
        panelController.hidePanel()
    }

    func finishClipboardDrag() {
        draggedClipboardItemID = nil
        searchState.ensureSelection(itemCount: currentFilteredItems.count)
        panelController.restoreKeyboardNavigationFocus()

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            panelController.restoreKeyboardNavigationFocus()
        }
    }

    var clearHistoryRequested = false

    private func setupHotkey() {
        KeyboardShortcuts.onKeyDown(for: .toggleHistoryPanel) { [weak self] in
            Task { @MainActor in
                self?.togglePanel()
            }
        }
        KeyboardShortcuts.onKeyDown(for: .clearHistory) { [weak self] in
            Task { @MainActor in
                guard self?.panelController.isVisible == true else { return }
                self?.clearHistoryRequested = true
            }
        }
        KeyboardShortcuts.onKeyDown(for: .togglePasteStack) { [weak self] in
            Task { @MainActor in
                self?.pasteStack.toggle()
            }
        }
    }
}
