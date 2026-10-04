import SwiftUI
import SwiftData

struct CardGridView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \ClipboardItem.copiedAt, order: .reverse)
    private var items: [ClipboardItem]
    @Query(sort: \Pinboard.displayOrder)
    private var pinboards: [Pinboard]

    @State private var filteredItems: [ClipboardItem] = []
    /// The first `suggestedCount` of `filteredItems` are suggestions.
    @State private var suggestedCount = 0
    /// Cards fading out of, then into, their places while Apple Intelligence's order swaps in.
    @State private var fadingIDs: Set<UUID> = []
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
                                        isSuggested: index < suggestedCount,
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
                                    .overlay(alignment: .trailing) {
                                        // In the gap after the last suggestion, taking no width, so every card keeps
                                        // the position `firstVisibleIndex` and the ⌘-numbers assume.
                                        if index == suggestedCount - 1, index < filteredItems.count - 1 {
                                            Capsule()
                                                .fill(DesignTokens.Brand.line)
                                                .frame(width: 2, height: DesignTokens.Card.height / 2)
                                                .offset(x: (DesignTokens.Card.gridSpacing + 2) / 2)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .opacity(fadingIDs.contains(item.id) ? 0 : 1)
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
        .onChange(of: appState.searchState.allowsSuggestions) { _, _ in
            guard appState.selectedTab == .history else { return }
            // Suggestions coming or going reorder the row: the focused card stays focused.
            let focused = appState.searchState.selectedIndex.flatMap {
                filteredItems.indices.contains($0) ? filteredItems[$0].id : nil
            }
            updateFilteredItems(from: items)
            if let focused, let index = appState.currentFilteredItems.firstIndex(where: { $0.id == focused }) {
                appState.searchState.selectedIndex = index
            }
        }
        .onChange(of: appState.suggestionsRerankID) { _, _ in
            guard appState.selectedTab == .history else { return }
            // Only the places whose card changes fade: out at the old order, in at the new one.
            let changed = zip(filteredItems.map(\.id), row(from: items).cards.map(\.id)).filter { $0 != $1 }
            fadingIDs = []
            guard !changed.isEmpty else { return updateFilteredItems(from: items) }
            withAnimation(.easeOut(duration: 0.1)) {
                fadingIDs = Set(changed.flatMap { [$0, $1] })
            } completion: {
                updateFilteredItems(from: items)
                withAnimation(.easeIn(duration: 0.15)) { fadingIDs = [] }
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

    /// The suggestions, then the usual cards without them.
    private func row(from sourceItems: [ClipboardItem]) -> (cards: [ClipboardItem], suggested: Int) {
        // Ranked on open; a suggestion deleted since then is simply gone.
        let suggested = appState.searchState.allowsSuggestions
            ? appState.suggestedIDs.compactMap { id in sourceItems.first { $0.id == id } }
            : []
        return (SuggestedRow.merge(suggested: suggested, rest: appState.searchState.filteredItems(from: sourceItems)),
                suggested.count)
    }

    private func updateFilteredItems(from sourceItems: [ClipboardItem]) {
        let (updated, suggested) = row(from: sourceItems)
        filteredItems = updated
        suggestedCount = suggested
        appState.currentSuggestedCount = suggested
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
