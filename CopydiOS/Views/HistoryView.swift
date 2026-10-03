import SwiftUI
import SwiftData

struct HistoryView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "All", text = "Text", links = "Links", images = "Images"
        var id: Self { self }
    }

    @Query(sort: \ClipboardItem.copiedAt, order: .reverse) private var items: [ClipboardItem]
    @State private var search = ""
    @State private var filter = Filter.all

    // ponytail: in-memory filter, move to #Predicate if history grows past a few thousand
    private var visible: [ClipboardItem] {
        items.filter { item in
            guard item.contentType != .fileURL else { return false }
            switch filter {
            case .all: break
            case .text: if ![.plainText, .richText, .html, .color].contains(item.contentType) { return false }
            case .links: if item.contentType != .url { return false }
            case .images: if item.contentType != .image { return false }
            }
            return search.isEmpty
                || (item.textContent?.localizedCaseInsensitiveContains(search) ?? false)
                || (item.userTitle?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Filter", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                ForEach(visible) { ClipRow(item: $0) }
            }
            .scrollContentBackground(.hidden)
            .background(DesignTokens.Brand.shelf)
            .overlay {
                if visible.isEmpty {
                    ContentUnavailableView(items.isEmpty ? "No clips yet" : "No results", systemImage: "clipboard")
                }
            }
            .searchable(text: $search)
            .navigationTitle("History")
        }
    }
}
