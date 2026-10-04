import SwiftUI
import SwiftData

struct CardGridView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \ClipboardItem.copiedAt, order: .reverse)
    private var items: [ClipboardItem]
    @Query(sort: \Pinboard.displayOrder)
    private var pinboards: [Pinboard]

    @State private var filteredItems: [ClipboardItem] = []
    @State private var lastOffset: CGFloat = 0

    var body: some View {
        Group {
            if filteredItems.isEmpty {
                PanelEmptyState(
                    title: appState.searchState.isActive ? "No Results" : "Copy anything",
                    systemImage: appState.searchState.isActive ? "magnifyingglass" : "clipboard",
                    message: appState.searchState.isActive
                        ? "Try a different search or filter"
                        : "Your clipboard history will appear here"
                )
            } else {
                Group {
                    let rows = [GridItem(.fixed(DesignTokens.Card.height))]

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: rows, spacing: DesignTokens.Card.gridSpacing) {
                                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                    let n = index - appState.firstVisibleIndex
                                    let selection = appState.searchState.multiSelection
                                    let selectionNumber = selection.number(of: item.id)
                                    ClipboardCardView(
                                        item: item,
                                        isSelected: selection.ids.isEmpty
                                            ? appState.searchState.selectedIndex == index
                                            : selectionNumber != nil,
                                        searchText: appState.searchState.debouncedSearchText,
                                        pinboards: pinboards,
                                        quickPasteNumber: (0...8).contains(n) ? n : nil,
                                        selectionNumber: selectionNumber,
                                        onSelect: { _ in
                                            appState.searchState.multiSelection.clear()
                                            appState.searchState.selectedIndex = index
                                        },
                                        onPaste: { selected in
                                            appState.clipboardMonitor.skipNextChange(picking: [selected.id])
                                            appState.pasteService.paste(item: selected)
                                            appState.hidePanel()
                                        },
                                        onDelete: {
                                            restoreSelectionAfterDeletingItem(at: index)
                                        },
                                        onCommandClick: { appState.toggleSelection(at: index) },
                                        onShiftClick: { appState.extendSelection(to: index) }
                                    )
                                    .id(item.id)
                                }
                            }
                            .padding(.horizontal, DesignTokens.Card.gridLeadingPadding)
                            .padding(.vertical, 8)
                            .trackScrollOffset(space: "cardGridScroll") { offset in
                                lastOffset = offset
                                syncFirstVisibleIndex()
                            }
                        }
                        .coordinateSpace(name: "cardGridScroll")
                        .onChange(of: appState.searchState.selectedIndex) { _, newIndex in
                            if let idx = newIndex, idx < filteredItems.count {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    proxy.scrollTo(filteredItems[idx].id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: items) { _, newItems in
            if appState.selectedTab == .history {
                updateFilteredItems(from: newItems)
            }
        }
        .onChange(of: appState.selectedTab) { _, newTab in
            if newTab == .history {
                syncFirstVisibleIndex()
                updateFilteredItems(from: items)
            }
        }
        .onChange(of: appState.panelPresentationID) { _, _ in
            if appState.selectedTab == .history {
                updateFilteredItems(from: items)
            }
        }
        .onChange(of: appState.searchState.debouncedSearchText) { _, _ in
            if appState.selectedTab == .history {
                updateFilteredItems(from: items)
            }
        }
        .onChange(of: appState.searchState.selectedContentTypes) { _, _ in
            if appState.selectedTab == .history {
                updateFilteredItems(from: items)
            }
        }
        .onChange(of: appState.searchState.dateFilter) { _, _ in
            if appState.selectedTab == .history {
                updateFilteredItems(from: items)
            }
        }
        .onAppear {
            updateFilteredItems(from: items)
        }
    }

    /// Writes the index only while History is the active tab; re-run on activation
    /// because this view stays mounted while another tab is shown.
    private func syncFirstVisibleIndex() {
        guard appState.selectedTab == .history else { return }
        let index = QuickPasteShortcut.firstVisibleIndex(scrollOffset: lastOffset)
        if appState.firstVisibleIndex != index { appState.firstVisibleIndex = index }
    }

    private func updateFilteredItems(from sourceItems: [ClipboardItem]) {
        let updated = appState.searchState.filteredItems(from: sourceItems)
        filteredItems = updated
        appState.currentFilteredItems = updated
        appState.currentFilteredQuery = appState.searchState.debouncedSearchText
        appState.searchState.ensureSelection(itemCount: updated.count)
    }

    private func restoreSelectionAfterDeletingItem(at deletedIndex: Int) {
        let remainingCount = max(filteredItems.count - 1, 0)
        guard remainingCount > 0 else {
            appState.searchState.selectedIndex = nil
            return
        }

        appState.searchState.selectedIndex = min(deletedIndex, remainingCount - 1)
    }
}

extension View {
    /// Reports the content's horizontal scroll offset (0 at rest, positive when scrolled right).
    /// Uses `onChange` inside a GeometryReader: `onPreferenceChange` does not refire on scroll.
    func trackScrollOffset(space: String, onChange: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                let offset = -geo.frame(in: .named(space)).minX
                Color.clear.onChange(of: offset, initial: true) { _, value in
                    onChange(value)
                }
            }
        )
    }
}

extension QuickPasteShortcut {
    static func firstVisibleIndex(scrollOffset: CGFloat) -> Int {
        firstVisibleIndex(
            scrollOffset: scrollOffset,
            cardWidth: DesignTokens.Card.width,
            spacing: DesignTokens.Card.gridSpacing,
            leadingPadding: DesignTokens.Card.gridLeadingPadding
        )
    }
}

struct PanelEmptyState: View {
    let title: LocalizedStringKey
    let systemImage: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tertiary)

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.78))

                Text(message)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
