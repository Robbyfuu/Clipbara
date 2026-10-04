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
    let suggestionModel = SuggestionModel()

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
    /// How many of `currentFilteredItems` are suggestions, at its front (updated by CardGridView).
    var currentSuggestedCount = 0
    /// Ranked when the panel opens, for the app it opened over.
    private(set) var suggestedIDs: [UUID] = []
    /// Bumped when Apple Intelligence reorders the open panel's suggestions, so the row crossfades to them.
    private(set) var suggestionsRerankID = 0
    /// The History row's focus right after this opening built it (set by CardGridView); nil until then.
    @ObservationIgnored var initialSelectedIndex: Int?
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
            self?.suggestionModel.cancel()
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
        initialSelectedIndex = nil
        suggestedIDs = rankSuggestions()
        panelPresentationID += 1
    }

    /// Once per opening: the last 200 clips plus pinned clips, never a file, ranked for the app the panel opened over.
    /// The habit's top 3 show at once; Apple Intelligence may reorder its top 15 within 600 ms.
    private func rankSuggestions() -> [UUID] {
        guard UserDefaults.standard.object(forKey: SuggestedRow.enabledDefaultsKey) as? Bool ?? true,
              let context = modelContainer?.mainContext else { return [] }
        suggestionModel.prewarm()
        let clips = SuggestionRanker.candidateClips(in: context)
        let candidates = clips.map { SuggestionRanker.Candidate(id: $0.id, copiedAt: $0.copiedAt, isPinned: $0.isPinned) }
        let events = ((try? context.fetch(FetchDescriptor<PasteEvent>())) ?? [])
            .map { SuggestionRanker.Event(clipID: $0.clipID, appBundleID: $0.appBundleID, at: $0.at) }
        let app = panelController.focusReturnApp
        let ranked = SuggestionRanker.rank(candidates: candidates, events: events, app: app?.bundleIdentifier,
                                           now: .now, limit: 15)
        if let app, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier {
            let byID = Dictionary(clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var pastes: [UUID: Int] = [:]
            for event in events where event.appBundleID == bundleID { pastes[event.clipID, default: 0] += 1 }
            let pastedHere = pastes.sorted { $0.value > $1.value }.prefix(5).compactMap { byID[$0.key] }
            suggestionModel.rerank(ranked.compactMap { byID[$0] }, pastedHere: pastedHere,
                                   appName: app.localizedName ?? bundleID, bundleID: bundleID) { [weak self] ids in
                // Only while the user hasn't touched the row since it opened; otherwise the habit order stays.
                guard let self, ids != self.suggestedIDs, self.selectedTab == .history,
                      self.searchState.mayReorderSuggestions(initialIndex: self.initialSelectedIndex) else { return }
                self.suggestedIDs = ids
                self.suggestionsRerankID += 1
            }
        }
        return Array(ranked.prefix(3))
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

    /// ⌥1-3: paste suggestion N as shown at the front of the History row. No-op when it isn't shown.
    func pasteSuggestion(number: Int) {
        guard selectedTab == .history, number < currentSuggestedCount,
              currentFilteredItems.indices.contains(number) else { return }
        paste(currentFilteredItems[number], asPlainText: nil)
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
