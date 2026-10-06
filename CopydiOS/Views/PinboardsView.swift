import SwiftUI
import SwiftData

struct PinboardsView: View {
    @Query(sort: \Pinboard.displayOrder) private var boards: [Pinboard]
    /// Every clip, for the automatic pinboards' counts. Each device sorts its own (`SmartKindsQueue`).
    @Query private var clips: [ClipboardItem]
    @AppStorage(SmartKinds.enabledDefaultsKey, store: SharedDefaults.store) private var smartBoardsEnabled = true
    @State private var path = NavigationPath()

    var body: some View {
        let automatic = smartCounts
        NavigationStack(path: $path) {
            List {
                ScreenTitle(text: String(localized: "Pinboards")).brandRow(top: 4, bottom: 9)
                ForEach(boards) { board in
                    Button { path.append(board) } label: {
                        card(board.name, count: board.entries.filter { $0.clipboardItem != nil }.count) {
                            Circle()
                                .fill(DesignTokens.pinboardDots[PinboardDot.index(for: board.id)])
                                .frame(width: 10, height: 10)
                        }
                    }
                    .buttonStyle(.plain)
                    .brandRow(top: 5, bottom: 5)
                }
                if boards.isEmpty { EmptyState(title: String(localized: "No pinboards yet"), symbol: "pin").brandRow() }
                if !automatic.isEmpty {
                    Text("Automatic")
                        .brandFont(13, .semibold, relativeTo: .footnote)
                        .foregroundStyle(DesignTokens.Brand.ink2)
                        .padding(.horizontal, 4)
                        .accessibilityAddTraits(.isHeader)
                        .brandRow(top: 19, bottom: 3)
                    ForEach(automatic, id: \.board) { board, count in
                        Button { path.append(board) } label: {
                            card(board.title, count: count) {
                                Image(systemName: "sparkles")
                                    .brandFont(13, .semibold, relativeTo: .footnote)
                                    .foregroundStyle(DesignTokens.Brand.ink2)
                            }
                        }
                        .buttonStyle(.plain)
                        .brandRow(top: 5, bottom: 5)
                    }
                }
            }
            .brandList()
            .navigationTitle("Pinboards")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Pinboard.self) { PinboardDetail(board: $0) }
            .navigationDestination(for: SmartBoard.self) { SmartBoardDetail(board: $0) }
        }
    }

    /// The type boards holding a clip History shows, with their counts, in order. None while the setting is off.
    // ponytail: one in-memory pass over every clip per render; a stored count if history grows past a few thousand.
    private var smartCounts: [(board: SmartBoard, count: Int)] {
        guard smartBoardsEnabled else { return [] }
        var counts = [Int](repeating: 0, count: SmartBoard.types.count)
        for clip in clips where clip.smartKinds != 0 && clip.contentType != .fileURL {
            for (index, board) in SmartBoard.types.enumerated() where clip.smartKinds & board.bit != 0 { counts[index] += 1 }
        }
        return zip(SmartBoard.types, counts).filter { $0.1 > 0 }.map { (board: $0.0, count: $0.1) }
    }

    private func card(_ name: String, count: Int, @ViewBuilder leading: () -> some View) -> some View {
        HStack(spacing: 12) {
            leading()
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(name)
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
                EmptyState(title: String(localized: "No clips in this pinboard yet"), symbol: "pin").brandRow()
            }
        }
        .brandList()
        .toolbarTitleDisplayMode(.inline)
    }
}

/// An automatic pinboard: History's rows, newest first, narrowed to the board's clips. Read-only.
private struct SmartBoardDetail: View {
    @Query(sort: \ClipboardItem.copiedAt, order: .reverse) private var items: [ClipboardItem]
    let board: SmartBoard

    var body: some View {
        let shown = items.filter {
            $0.contentType != .fileURL && SmartKinds.members(of: board, kinds: $0.smartKinds, topic: nil)
        }
        List {
            ScreenTitle(text: board.title).brandRow(top: 4, bottom: 9)
            ForEach(shown) { ClipRow(item: $0) }
            if shown.isEmpty { EmptyState(title: String(localized: "No clips yet"), symbol: "sparkles").brandRow() }
        }
        .brandList()
        .toolbarTitleDisplayMode(.inline)
    }
}
