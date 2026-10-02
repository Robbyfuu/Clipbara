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

    #if CLOUDSYNC
    private(set) var cloudSync: CloudSyncEngine?
    #endif

    @ObservationIgnored private var hasStarted = false

    func start(modelContext: ModelContext, modelContainer: ModelContainer) {
        // App.init may run more than once; start the monitor and hotkeys only once.
        guard !hasStarted else { return }
        hasStarted = true
        self.modelContainer = modelContainer
        clipboardMonitor.start(modelContext: modelContext)
        ReviewPrompter.noteLaunch()
        #if APPSTORE
        Entitlements.shared.start()
        #endif
        panelController.onPanelWillHide = { [weak self] in
            self?.searchState.reset()
            self?.previewItem = nil
            ReviewPrompter.panelWillHide { [weak self] in
                self?.panelController.isVisible ?? false
            }
        }
        setupHotkey()

        #if CLOUDSYNC
        let engine = CloudSyncEngine(container: modelContainer) { [weak self] in
            self?.clipboardMonitor.refreshLatestItems()
        }
        cloudSync = engine
        if UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey) {
            engine.start()
        }
        #endif

        // Render the panel once off screen so the first hotkey press is instant.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let container = self.modelContainer else { return }
            self.panelController.prewarm(modelContainer: container, appState: self)
        }
    }

    func togglePanel() {
        guard let container = modelContainer else { return }
        #if APPSTORE
        // Without an active trial or unlock, offer it instead of the history.
        // Clipboard capture keeps running, so nothing is lost in the meantime.
        if !panelController.isVisible, !Entitlements.shared.checkHistoryAccess() {
            PaywallWindowController.shared.show()
            return
        }
        #endif
        #if CLOUDSYNC
        if !panelController.isVisible { cloudSync?.fetchIfStale() }
        #endif
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
        clipboardMonitor.skipNextChange()
        pasteService.paste(item: item, asPlainText: asPlainText)
        hidePanel()
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
        panelController.restoreKeyboardNavigationFocus(activateApp: true)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            panelController.restoreKeyboardNavigationFocus(activateApp: true)
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
    }
}
