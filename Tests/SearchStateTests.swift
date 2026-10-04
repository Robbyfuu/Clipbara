import SwiftData
import XCTest

@MainActor
final class SearchStateTests: XCTestCase {
    private var container: ModelContainer!

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func clip(_ type: ContentType) -> ClipboardItem {
        let item = ClipboardItem(contentType: type, rawData: Data(), textContent: type.rawValue, contentHash: UUID().uuidString)
        container.mainContext.insert(item)
        return item
    }

    func testTypeMenuHasOneFilesEntry() {
        XCTAssertEqual(SearchState.filterableTypes.filter { $0.displayName == ContentType.files.displayName }, [.files])
        XCTAssertFalse(SearchState.filterableTypes.contains(.fileURL))
    }

    func testFilesFilterCoversCopiedFilesAndFileLinks() {
        let items = [clip(.files), clip(.fileURL), clip(.plainText)]
        let state = SearchState()
        state.toggleContentType(.files)
        XCTAssertEqual(state.filteredItems(from: items).map(\.contentType), [.files, .fileURL])
        state.toggleContentType(.files)
        state.toggleContentType(.plainText)
        XCTAssertEqual(state.filteredItems(from: items).map(\.contentType), [.plainText])
    }

    func testSuggestionsHideWhileSearchingFilteringOrMultiSelecting() {
        let state = SearchState()
        XCTAssertTrue(state.allowsSuggestions)
        state.updateSearch("a")
        XCTAssertFalse(state.allowsSuggestions, "search text")
        state.clearSearch()
        state.toggleContentType(.image)
        XCTAssertFalse(state.allowsSuggestions, "type filter")
        state.toggleContentType(.image)
        state.dateFilter = .today
        XCTAssertFalse(state.allowsSuggestions, "date filter")
        state.dateFilter = .all
        _ = state.multiSelection.toggle(1, focus: 0, in: [UUID(), UUID()])
        XCTAssertFalse(state.allowsSuggestions, "multi-select")
        state.multiSelection.clear()
        XCTAssertTrue(state.allowsSuggestions)
    }

    /// Apple Intelligence's order lands only while the row is as the panel opened it, so it never moves the user.
    func testSuggestionsReorderOnlyBeforeTheUserMovesTypesOrMultiSelects() {
        let state = SearchState()
        XCTAssertFalse(state.mayReorderSuggestions(initialIndex: nil), "the History row has not shown yet")
        state.ensureSelection(itemCount: 5)
        XCTAssertTrue(state.mayReorderSuggestions(initialIndex: 0))
        state.moveSelection(by: 1, maxIndex: 4)
        XCTAssertFalse(state.mayReorderSuggestions(initialIndex: 0), "moved")
        state.moveSelection(by: -1, maxIndex: 4)
        state.updateSearch("g")
        state.ensureSelection(itemCount: 5)
        XCTAssertFalse(state.mayReorderSuggestions(initialIndex: 0), "typed")
        state.clearSearch()
        state.ensureSelection(itemCount: 5)
        state.toggleContentType(.url)
        state.ensureSelection(itemCount: 5)
        XCTAssertFalse(state.mayReorderSuggestions(initialIndex: 0), "filtered")
        state.toggleContentType(.url)
        state.ensureSelection(itemCount: 5)
        _ = state.multiSelection.toggle(1, focus: 0, in: (0..<5).map { _ in UUID() })
        XCTAssertFalse(state.mayReorderSuggestions(initialIndex: 0), "multi-select")
    }
}
