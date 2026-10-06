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

    /// Multi-select picks from the row as shown, so the suggestions stay put while it's active.
    func testSuggestionsHideWhileSearchingOrFilteringButNotWhileMultiSelecting() {
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
        XCTAssertTrue(state.allowsSuggestions, "multi-select")
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

    /// Search reads a secret's masked label, never the secret itself.
    func testSearchMatchesASecretsMaskNotItsText() {
        let secret = clip(.plainText)
        secret.textContent = FakeSecret.stripe
        secret.isSensitive = true
        let state = SearchState()
        state.debouncedSearchText = "sk_live"
        XCTAssertEqual(state.filteredItems(from: [secret]).map(\.id), [])
        state.debouncedSearchText = "API key"
        XCTAssertEqual(state.filteredItems(from: [secret]).map(\.id), [secret.id])
        state.debouncedSearchText = "p7dc"
        XCTAssertEqual(state.filteredItems(from: [secret]).map(\.id), [secret.id], "the last four show, so they match")
    }

    /// An image is found by the text recognized in it.
    func testSearchMatchesTheTextInAnImage() {
        let image = clip(.image)
        image.textContent = nil
        image.ocrText = "Invoice 2026\nCopyd OCR test"
        let state = SearchState()
        state.debouncedSearchText = "ocr TEST"
        XCTAssertEqual(state.filteredItems(from: [image, clip(.plainText)]).map(\.id), [image.id])
        state.debouncedSearchText = "receipt"
        XCTAssertEqual(state.filteredItems(from: [image]).map(\.id), [])
    }

    /// A link is found by its fetched page title, unless previews are off.
    func testSearchMatchesALinksTitle() {
        let link = clip(.url)
        link.textContent = "https://www.apple.com/iphone"
        link.linkTitle = "iPhone - Apple"
        let state = SearchState()
        state.debouncedSearchText = "IPHONE - apple"
        XCTAssertEqual(state.filteredItems(from: [link, clip(.plainText)]).map(\.id), [link.id])
        XCTAssertEqual(state.filteredItems(from: [link], linkTitles: false).map(\.id), [])
    }
}
