import Combine
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

private enum DroppedClipResult {
    case added(String)
    case alreadyAdded(String)
    case missing
}

struct NavigationBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Pinboard.displayOrder) private var pinboards: [Pinboard]
    @Query(sort: \ClipboardItem.copiedAt, order: .reverse) private var historyItems: [ClipboardItem]
    @Query private var pinboardEntries: [PinboardEntry]
    @AppStorage(SmartKinds.enabledDefaultsKey) private var smartBoardsEnabled = true
    @AppStorage(TopicPlan.enabledDefaultsKey) private var smartTopicsEnabled = true
    /// The type boards, then the topic boards, holding a clip, in order; none while "Automatic pinboards" is off.
    /// Counted in the store.
    @State private var smartBoards: [SmartBoard] = []

    @State private var isAddingPinboard = false
    @State private var newPinboardName = ""
    @State private var renamingPinboard: Pinboard?
    @State private var deletingPinboard: Pinboard?
    @State private var targetedPinboardID: UUID?
    @State private var renameText = ""
    @State private var isShowingClearAlert = false
    @State private var tabsWidth: CGFloat = 0
    @FocusState private var isSearchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        navigationBar
        .frame(height: DesignTokens.Nav.height)
        .onAppear {
            appState.orderedPinboardIDs = pinboards.map(\.id)
            refreshSmartBoards()
            appState.orderedSmartBoards = smartBoards
        }
        .onChange(of: smartBoardsEnabled) { _, _ in refreshSmartBoards() }
        .onChange(of: smartTopicsEnabled) { _, _ in refreshSmartBoards() }
        // A sort pass saves every 50 clips: one refetch once the saves pause.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in refreshSmartBoards() }
        .onChange(of: pinboards.map(\.id)) { _, ids in
            appState.orderedPinboardIDs = ids
        }
        .onChange(of: smartBoards) { _, boards in
            appState.orderedSmartBoards = boards
            // Its last clip went, or the setting was turned off: the tab is gone.
            if let board = appState.selectedTab.smartBoard, !boards.contains(board) {
                appState.panelController.selectTab(.history)
            }
        }
        .alert("Create Pinboard", isPresented: $isAddingPinboard) {
            TextField("Name", text: $newPinboardName)
            Button("Cancel", role: .cancel) { newPinboardName = "" }
            Button("Create") { createPinboard() }
        }
        .onChange(of: appState.clearHistoryRequested) { _, newValue in
            if newValue {
                appState.clearHistoryRequested = false
                isShowingClearAlert = clearableHistoryCount > 0
            }
        }
        .alert("Clear Clipboard History?", isPresented: $isShowingClearAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear History", role: .destructive) { clearHistory() }
        } message: {
            Text("This deletes \(clearableHistoryCount) unpinned clips from history. Pinboard items stay available.")
        }
        .alert("Delete Pinboard?", isPresented: .init(
            get: { deletingPinboard != nil },
            set: { if !$0 { deletingPinboard = nil } }
        )) {
            Button("Cancel", role: .cancel) { deletingPinboard = nil }
            Button("Delete Pinboard", role: .destructive) {
                if let deletingPinboard {
                    deletePinboard(deletingPinboard)
                }
                deletingPinboard = nil
            }
        } message: {
            Text("This removes the pinboard only. The clips stay in clipboard history.")
        }
        .alert("Rename Pinboard", isPresented: .init(
            get: { renamingPinboard != nil },
            set: { if !$0 { renamingPinboard = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingPinboard = nil }
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    renamingPinboard?.name = trimmed
                    try? modelContext.save()
                }
                renamingPinboard = nil
            }
        }
    }

    // MARK: - Navigation Bar (default state)

    private var navigationBar: some View {
        HStack(spacing: 12) {
            CopydMark(size: 24)

            tabGroup
                .layoutPriority(1)

            searchField
                .frame(maxWidth: 420)
                .frame(minWidth: 120, maxWidth: .infinity)

            actionGroup
                .navGlassContainer()
        }
        .padding(.horizontal, 16)
        .background(
            // Command-F focuses the search field; nothing else handled it before.
            Button("") { isSearchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .focusable(false)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private var tabGroup: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    navTab(
                        label: String(localized: "History"),
                        dotColor: nil,
                        isActive: appState.selectedTab == .history
                    ) {
                        appState.panelController.selectTab(.history)
                    }
                    .id(PanelTab.history)
                    .help(PanelTabShortcut.hint(at: 0).map { String(localized: "History (\($0))") } ?? String(localized: "History"))

                    ForEach(Array(pinboards.enumerated()), id: \.element.id) { index, pinboard in
                        navTab(
                            label: pinboard.name,
                            dotColor: DesignTokens.pinboardDots[PinboardDot.index(for: pinboard.id)],
                            isActive: appState.selectedTab == .pinboard(pinboard.id),
                            isDropTargeted: targetedPinboardID == pinboard.id
                        ) {
                            appState.panelController.selectTab(.pinboard(pinboard.id))
                        }
                        .id(PanelTab.pinboard(pinboard.id))
                        .help(PanelTabShortcut.hint(at: index + 1).map { "\(pinboard.name) (\($0))" } ?? pinboard.name)
                        .onDrop(
                            of: [.copydClipboardItemID, .text, .url, .fileURL, .image, .data, .item],
                            isTargeted: dropTargetBinding(for: pinboard.id)
                        ) { providers in
                            addDroppedClip(from: providers, to: pinboard.id)
                        }
                        .contextMenu {
                            Button("Rename Pinboard") {
                                renameText = pinboard.name
                                renamingPinboard = pinboard
                            }
                            Divider()
                            Button("Delete Pinboard", role: .destructive) {
                                deletingPinboard = pinboard
                            }
                        }
                    }

                    // Automatic pinboards: read-only, so no menu and no drop. Published by `onChange(of: smartBoards)`,
                    // so the tabs and ⌥⌘ numbers always follow the same list.
                    ForEach(Array(appState.orderedSmartBoards.enumerated()), id: \.element) { index, board in
                        navTab(
                            label: board.title,
                            dotColor: nil,
                            symbol: "sparkles",
                            isActive: appState.selectedTab == .smart(board)
                        ) {
                            appState.panelController.selectTab(.smart(board))
                        }
                        .id(PanelTab.smart(board))
                        .help(PanelTabShortcut.hint(at: pinboards.count + index + 1).map { "\(board.title) (\($0))" }
                              ?? board.title)
                    }

                    NavIconButton(icon: "plus", iconSize: 12) {
                        newPinboardName = nextPinboardName()
                        isAddingPinboard = true
                    }
                    .help("New Pinboard")
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabsWidth = $0 }
            }
            // Hug the tabs so the search field gets the rest; scroll only on overflow.
            .frame(maxWidth: tabsWidth > 0 ? tabsWidth : .infinity)
            .onChange(of: appState.selectedTab) { _, tab in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(tab, anchor: .center)
                }
            }
        }
    }

    private var actionGroup: some View {
        HStack(spacing: 4) {
            if let engine = appState.cloudSync, engine.status != .off {
                TimelineView(.everyMinute) { context in
                    if let text = SyncChip.text(for: engine.status, now: context.date) {
                        Button {
                            // Panel is non-activating and floating: hide it so Settings is not covered.
                            appState.hidePanel()
                            openSettings()
                            NSApp.activate(ignoringOtherApps: true)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "lock.fill").font(.system(size: 11))
                                Text(text).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(DesignTokens.Brand.ink2)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .navSurface(DesignTokens.Brand.chip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("iCloud Sync")
                    }
                }
            }

            optionsMenuButton

            if appState.selectedTab == .history {
                NavIconButton(icon: "trash", iconSize: 13) {
                    isShowingClearAlert = true
                }
                .disabled(clearableHistoryCount == 0)
                .opacity(clearableHistoryCount == 0 ? 0.45 : 1)
                .help(clearableHistoryCount == 0
                    ? String(localized: "No unpinned history to clear")
                    : String(localized: "Clear Clipboard History"))
            }
        }
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.Brand.ink2)

            TextField("Search clipboard...", text: searchTextBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Brand.ink)
                .focused($isSearchFocused)

            if !appState.searchState.searchText.isEmpty {
                Button {
                    appState.searchState.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.Brand.ink2)
                }
                .buttonStyle(.plain)
            }

            Text("⌘F")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.Brand.ink2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(DesignTokens.Brand.line, lineWidth: 1)
                )
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .navSurface(DesignTokens.Brand.chip, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Tab Component

    private func navTab(
        label: String,
        dotColor: Color?,
        symbol: String? = nil,
        isActive: Bool,
        isDropTargeted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        NavTabButton(
            label: label,
            dotColor: dotColor,
            symbol: symbol,
            isActive: isActive,
            isDropTargeted: isDropTargeted,
            action: action
        )
    }

    // MARK: - Bindings & Actions

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { appState.searchState.searchText },
            set: { appState.searchState.updateSearch($0) }
        )
    }

    private var optionsMenuButton: some View {
        OptionsMenuButton(searchState: appState.searchState)
    }

    /// One `fetchCount` per board, never a pass over every clip.
    private func refreshSmartBoards() {
        let boards = smartBoardsEnabled
            ? ((try? SmartKinds.counts(in: modelContext, boards: SmartBoard.listed, limit: 1)) ?? []).map(\.board) : []
        if boards != smartBoards { smartBoards = boards }
    }

    private var pinnedItemIDs: Set<UUID> {
        Set(pinboardEntries.compactMap { $0.clipboardItem?.id })
    }

    private var clearableHistoryItems: [ClipboardItem] {
        let pinned = pinnedItemIDs
        return historyItems.filter { !pinned.contains($0.id) }
    }

    private var clearableHistoryCount: Int {
        clearableHistoryItems.count
    }

    private func dropTargetBinding(for pinboardId: UUID) -> Binding<Bool> {
        Binding(
            get: { targetedPinboardID == pinboardId },
            set: { isTargeted in
                targetedPinboardID = isTargeted ? pinboardId : nil
            }
        )
    }

    private func createPinboard() {
        let trimmed = newPinboardName.trimmingCharacters(in: .whitespaces)
        let name = trimmed.isEmpty ? nextPinboardName() : uniquePinboardName(preferred: trimmed)
        let nextOrder = (pinboards.map(\.displayOrder).max() ?? -1) + 1
        let pinboard = Pinboard(name: name, displayOrder: nextOrder)
        modelContext.insert(pinboard)
        try? modelContext.save()
        newPinboardName = ""
        // Keep shortcut positions current until @Query publishes the insert.
        appState.orderedPinboardIDs = pinboards.filter { $0.id != pinboard.id }.map(\.id) + [pinboard.id]
        appState.panelController.selectTab(.pinboard(pinboard.id))
    }

    private func clearHistory() {
        for item in clearableHistoryItems {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }

    private func addDroppedClip(from providers: [NSItemProvider], to pinboardId: UUID) -> Bool {
        if let draggedID = appState.draggedClipboardItemID {
            showDropResult(addClip(itemId: draggedID, toPinboard: pinboardId))
            targetedPinboardID = nil
            appState.finishClipboardDrag()
            return true
        }

        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.copydClipboardItemID.identifier)
        }) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.copydClipboardItemID.identifier) { data, _ in
            guard
                let data,
                let idString = String(data: data, encoding: .utf8),
                let itemId = UUID(uuidString: idString)
            else { return }

            Task { @MainActor in
                showDropResult(addClip(itemId: itemId, toPinboard: pinboardId))
                targetedPinboardID = nil
                appState.finishClipboardDrag()
            }
        }

        return true
    }

    private func addClip(itemId: UUID, toPinboard pinboardId: UUID) -> DroppedClipResult {
        guard
            let item = historyItems.first(where: { $0.id == itemId }),
            let pinboard = pinboards.first(where: { $0.id == pinboardId })
        else {
            return .missing
        }

        let alreadyAdded = pinboard.entries.contains { $0.clipboardItem?.id == itemId }
        guard !alreadyAdded else { return .alreadyAdded(pinboard.name) }

        let nextOrder = (pinboard.entries.map(\.displayOrder).max() ?? -1) + 1
        let entry = PinboardEntry(clipboardItem: item, pinboard: pinboard, displayOrder: nextOrder)
        modelContext.insert(entry)
        item.isPinned = true
        try? modelContext.save()
        return .added(pinboard.name)
    }

    private func showDropResult(_ result: DroppedClipResult) {
        switch result {
        case .added(let name):
            appState.showToast(String(localized: "Added to \(name)"))
        case .alreadyAdded(let name):
            appState.showToast(String(localized: "Already in \(name)"), systemImage: "checkmark.circle")
        case .missing:
            appState.showToast(String(localized: "Could not add clip"), systemImage: "exclamationmark.triangle.fill")
        }
    }

    private func nextPinboardName() -> String {
        uniquePinboardName(preferred: String(localized: "Pinboard"))
    }

    private func uniquePinboardName(preferred: String) -> String {
        let existingNames = Set(pinboards.map(\.name))
        guard existingNames.contains(preferred) else { return preferred }

        var index = 2
        while existingNames.contains("\(preferred) \(index)") {
            index += 1
        }
        return "\(preferred) \(index)"
    }

    private func deletePinboard(_ pinboard: Pinboard) {
        if appState.selectedTab == .pinboard(pinboard.id) {
            appState.panelController.selectTab(.history)
        }
        appState.orderedPinboardIDs.removeAll { $0 == pinboard.id }
        modelContext.delete(pinboard)
        try? modelContext.save()
    }
}

// MARK: - NavTabButton (extracted for @State hover)

private struct NavTabButton: View {
    let label: String
    let dotColor: Color?
    /// An automatic pinboard's ✨, in place of the dot.
    var symbol: String? = nil
    let isActive: Bool
    let isDropTargeted: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let dotColor {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                }
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                }

                Text(label)
                    .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? DesignTokens.Brand.onButter : DesignTokens.Brand.ink2)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                isActive ? DesignTokens.Brand.butter
                    : isDropTargeted ? DesignTokens.Brand.butter.opacity(0.35)
                    : isHovered ? DesignTokens.Brand.chip
                    : Color.clear,
                in: Capsule()
            )
            .navGlass(in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    isDropTargeted ? DesignTokens.Brand.butter : Color.clear,
                    lineWidth: 1.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: isDropTargeted)
    }
}

// MARK: - NavIconButton (icon-only button with hover)

private struct NavIconButton: View {
    let icon: String
    let iconSize: CGFloat
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(DesignTokens.Brand.ink2)
                .frame(width: 32, height: 32)
                .background(
                    isHovered ? DesignTokens.Brand.chip : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .navGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Liquid Glass (macOS 26+)

// Tints are fills laid on the glass as content, never `Glass.tint(_:)`: glass tints render only
// while the app is active, and this non-activating panel is used while another app is frontmost.
private extension View {
    /// macOS 26+: Liquid Glass behind the view's fills, in `shape`. Earlier: unchanged.
    @ViewBuilder
    func navGlass(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            self
        }
    }

    /// macOS 26+: plain Liquid Glass in `shape`. Earlier: `background(fill, in: shape)`, as before.
    @ViewBuilder
    func navSurface(_ fill: Color, in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(fill, in: shape)
        }
    }

    /// Renders a group's glass together; spacing 0 keeps each control its own shape at rest.
    /// Not used on the tab strip: outside its ScrollView a container lifts the pills out of the
    /// scroll clip, and inside it the container squeezes the pills until their labels truncate.
    @ViewBuilder
    func navGlassContainer() -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 0) { self }
        } else {
            self
        }
    }
}

/// Maps the engine status to the top-bar chip text; nil hides the chip.
enum SyncChip {
    static func text(for status: CloudSyncEngine.Status, now: Date) -> String? {
        switch status {
        case .off: return nil
        case .syncing: return String(localized: "Syncing…")
        case .upToDate(let date):
            let minutes = Int(now.timeIntervalSince(date) / 60)
            return minutes < 1 ? String(localized: "Synced · now") : String(localized: "Synced · \(minutes) min")
        default: return String(localized: "Sync paused")
        }
    }
}

// MARK: - OptionsMenuButton (NSMenu-based for proper centering)

private struct OptionsMenuButton: View {
    let searchState: SearchState

    var body: some View {
        NavIconButton(icon: "ellipsis", iconSize: 14) {
            showMenu()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        // Filter by Type submenu
        let typeMenu = NSMenu()
        for type in SearchState.filterableTypes {
            let item = NSMenuItem(title: type.displayName, action: nil, keyEquivalent: "")
            let isSelected = searchState.selectedContentTypes.contains(type)
            if isSelected {
                item.state = .on
            }
            item.target = MenuActionTarget.shared
            item.representedObject = MenuAction.toggleContentType(type, searchState)
            item.action = #selector(MenuActionTarget.performAction(_:))
            typeMenu.addItem(item)
        }
        if !searchState.selectedContentTypes.isEmpty {
            typeMenu.addItem(.separator())
            let clearItem = NSMenuItem(title: String(localized: "Clear Filters"), action: nil, keyEquivalent: "")
            clearItem.target = MenuActionTarget.shared
            clearItem.representedObject = MenuAction.clearContentTypes(searchState)
            clearItem.action = #selector(MenuActionTarget.performAction(_:))
            typeMenu.addItem(clearItem)
        }
        let typeMenuItem = NSMenuItem(title: String(localized: "Filter by Type"), action: nil, keyEquivalent: "")
        typeMenuItem.submenu = typeMenu
        menu.addItem(typeMenuItem)

        // Filter by Date submenu
        let dateMenu = NSMenu()
        for filter in SearchState.DateFilter.allCases {
            let item = NSMenuItem(title: filter.displayName, action: nil, keyEquivalent: "")
            if searchState.dateFilter == filter {
                item.state = .on
            }
            item.target = MenuActionTarget.shared
            item.representedObject = MenuAction.setDateFilter(filter, searchState)
            item.action = #selector(MenuActionTarget.performAction(_:))
            dateMenu.addItem(item)
        }
        let dateMenuItem = NSMenuItem(title: String(localized: "Filter by Date"), action: nil, keyEquivalent: "")
        dateMenuItem.submenu = dateMenu
        menu.addItem(dateMenuItem)

        // Show menu at mouse location
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - NSMenu action helpers

private enum MenuAction {
    case toggleContentType(ContentType, SearchState)
    case clearContentTypes(SearchState)
    case setDateFilter(SearchState.DateFilter, SearchState)
}

@MainActor
private final class MenuActionTarget: NSObject {
    static let shared = MenuActionTarget()

    @objc func performAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        Task { @MainActor in
            switch action {
            case .toggleContentType(let type, let state):
                state.toggleContentType(type)
            case .clearContentTypes(let state):
                state.selectedContentTypes = []
            case .setDateFilter(let filter, let state):
                state.dateFilter = filter
            }
        }
    }
}
