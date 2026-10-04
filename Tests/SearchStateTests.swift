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
}
