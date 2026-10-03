import SwiftUI
import SwiftData

struct PinboardsView: View {
    @Query(sort: \Pinboard.displayOrder) private var boards: [Pinboard]
    @State private var path: [Pinboard] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ScreenTitle(text: "Pinboards").brandRow(top: 4, bottom: 9)
                ForEach(boards) { board in
                    Button { path.append(board) } label: { card(board) }
                        .buttonStyle(.plain)
                        .brandRow(top: 5, bottom: 5)
                }
                if boards.isEmpty { EmptyState(title: "No pinboards yet", symbol: "pin").brandRow() }
            }
            .brandList()
            .navigationTitle("Pinboards")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Pinboard.self) { PinboardDetail(board: $0) }
        }
    }

    private func card(_ board: Pinboard) -> some View {
        let count = board.entries.filter { $0.clipboardItem != nil }.count
        return HStack(spacing: 12) {
            Circle()
                .fill(DesignTokens.pinboardDots[PinboardDot.index(for: board.id)])
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(board.name)
                .brandFont(17, .semibold, relativeTo: .headline)
                .foregroundStyle(DesignTokens.Brand.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text("\(count)")
                .brandFont(15, relativeTo: .subheadline)
                .foregroundStyle(DesignTokens.Brand.ink2)
                .accessibilityLabel(count == 1 ? "1 clip" : "\(count) clips")
            Image(systemName: "chevron.right")
                .brandFont(13, .semibold, relativeTo: .footnote)
                .foregroundStyle(DesignTokens.Brand.ink2)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .brandCard()
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct PinboardDetail: View {
    @Environment(\.modelContext) private var modelContext
    let board: Pinboard

    var body: some View {
        let entries = board.entries.filter { $0.clipboardItem != nil }.sorted { $0.displayOrder < $1.displayOrder }
        List {
            ScreenTitle(text: board.name).brandRow(top: 4, bottom: 9)
            ForEach(entries) { entry in
                if let item = entry.clipboardItem {
                    ClipRow(item: item) {
                        modelContext.delete(entry)
                        try? modelContext.save()
                    }
                }
            }
            if entries.isEmpty {
                EmptyState(title: "No clips in this pinboard yet", symbol: "pin").brandRow()
            }
        }
        .brandList()
        .toolbarTitleDisplayMode(.inline)
    }
}
