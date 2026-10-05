import SwiftUI

@MainActor
@Observable
final class SearchState {
    var searchText: String = ""
    var debouncedSearchText: String = ""
    var selectedContentTypes: Set<ContentType> = []
    var dateFilter: DateFilter = .all
    var selectedIndex: Int? = nil
    /// Cards picked for a joined paste; empty while only `selectedIndex` is selected.
    var multiSelection = MultiSelection()

    private var debounceTask: Task<Void, Never>?

    enum DateFilter: String, CaseIterable, Sendable {
        case all = "All"
        case today = "Today"
        case thisWeek = "This Week"
        case thisMonth = "This Month"

        /// Localized menu title. `rawValue` stays the stable English identifier.
        var displayName: String {
            switch self {
            case .all: String(localized: "All")
            case .today: String(localized: "Today")
            case .thisWeek: String(localized: "This Week")
            case .thisMonth: String(localized: "This Month")
            }
        }

        var startDate: Date? {
            let calendar = Calendar.current
            switch self {
            case .all: return nil
            case .today: return calendar.startOfDay(for: Date())
            case .thisWeek:
                return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
            case .thisMonth:
                return calendar.date(from: calendar.dateComponents([.year, .month], from: Date()))
            }
        }
    }

    /// The Filter by Type menu. One "Files" entry covers copied files and the older local file links.
    static let filterableTypes = ContentType.allCases.filter { $0 != .fileURL }

    var isActive: Bool {
        !searchText.isEmpty || !selectedContentTypes.isEmpty || dateFilter != .all
    }

    /// Suggestions lead the History row while nothing narrows it. Multi-select keeps them in place: their cards are
    /// picked like any other, and the row never reshuffles under the selection.
    var allowsSuggestions: Bool { !isActive }

    /// Apple Intelligence's order may replace the habit's only while the row is as the panel opened it: focus still at
    /// `initialIndex` (nil until the History row has shown), nothing typed or filtered, no multi-selection.
    func mayReorderSuggestions(initialIndex: Int?) -> Bool {
        initialIndex != nil && selectedIndex == initialIndex && !isActive && multiSelection.ids.isEmpty
    }

    func updateSearch(_ text: String) {
        searchText = text
        selectedIndex = nil
        multiSelection.clear()
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            debouncedSearchText = text
        }
    }

    func reset() {
        searchText = ""
        debouncedSearchText = ""
        selectedContentTypes = []
        dateFilter = .all
        selectedIndex = nil
        multiSelection.clear()
        debounceTask?.cancel()
    }

    func clearSearch() {
        searchText = ""
        debouncedSearchText = ""
        selectedIndex = nil
        multiSelection.clear()
        debounceTask?.cancel()
    }

    func toggleContentType(_ type: ContentType) {
        if selectedContentTypes.contains(type) {
            selectedContentTypes.remove(type)
        } else {
            selectedContentTypes.insert(type)
        }
        selectedIndex = nil
        multiSelection.clear()
    }

    func filteredItems(from items: [ClipboardItem]) -> [ClipboardItem] {
        let startDate = dateFilter.startDate
        let contentTypes = selectedContentTypes
        let query = debouncedSearchText

        guard startDate != nil || !contentTypes.isEmpty || !query.isEmpty else {
            return items
        }

        return items.filter { item in
            if let startDate, item.copiedAt < startDate {
                return false
            }

            if !contentTypes.isEmpty, !contentTypes.contains(item.contentType == .fileURL ? .files : item.contentType) {
                return false
            }

            if !query.isEmpty {
                return item.matchesSearchQuery(query)
            }

            return true
        }
    }

    func moveSelection(by offset: Int, maxIndex: Int) {
        guard maxIndex >= 0 else { selectedIndex = nil; return }
        if let current = selectedIndex {
            selectedIndex = max(0, min(current + offset, maxIndex))
        } else {
            selectedIndex = 0
        }
    }

    func ensureSelection(itemCount: Int) {
        guard itemCount > 0 else {
            selectedIndex = nil
            return
        }

        if let current = selectedIndex {
            selectedIndex = max(0, min(current, itemCount - 1))
        } else {
            selectedIndex = 0
        }
    }
}

private extension ClipboardItem {
    /// A secret matches by its masked label only, never by the secret itself. An image also by the text read in it.
    func matchesSearchQuery(_ query: String) -> Bool {
        (secretMask ?? textContent)?.localizedCaseInsensitiveContains(query) == true ||
        sourceAppName?.localizedCaseInsensitiveContains(query) == true ||
        userTitle?.localizedCaseInsensitiveContains(query) == true ||
        recognizedText?.localizedCaseInsensitiveContains(query) == true
    }
}
