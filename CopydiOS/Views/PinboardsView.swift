import SwiftUI
import SwiftData

struct PinboardsView: View {
    @Query(sort: \Pinboard.displayOrder) private var boards: [Pinboard]

    var body: some View {
        NavigationStack {
            List(boards) { board in
                NavigationLink(board.name) { PinboardDetail(board: board) }
                    .foregroundStyle(DesignTokens.Brand.ink)
                    .listRowBackground(DesignTokens.Brand.card)
            }
            .scrollContentBackground(.hidden)
            .background(DesignTokens.Brand.shelf)
            .overlay { if boards.isEmpty { ContentUnavailableView("No pinboards yet", systemImage: "pin") } }
            .navigationTitle("Pinboards")
        }
    }
}

private struct PinboardDetail: View {
    @Environment(\.modelContext) private var modelContext
    let board: Pinboard

    var body: some View {
        List(board.entries.sorted { $0.displayOrder < $1.displayOrder }) { entry in
            if let item = entry.clipboardItem {
                ClipRow(item: item) {
                    modelContext.delete(entry)
                    try? modelContext.save()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DesignTokens.Brand.shelf)
        .navigationTitle(board.name)
    }
}
