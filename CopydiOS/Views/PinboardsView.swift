import Combine
import SwiftUI
import SwiftData

struct PinboardsView: View {
    @Query(sort: \Pinboard.displayOrder) private var boards: [Pinboard]
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SmartKinds.enabledDefaultsKey, store: SharedDefaults.store) private var smartBoardsEnabled = true
    @AppStorage(TopicPlan.enabledDefaultsKey, store: SharedDefaults.store) private var smartTopicsEnabled = true
    /// The type boards, then the topic boards, holding a clip History shows, with their counts, in order. Each device
    /// sorts its own clips (`SmartKindsQueue`, `TopicQueue`); they are counted in the store.
    @State private var automatic: [(board: SmartBoard, count: Int)] = []
    @State private var path = NavigationPath()

    var body: some View {
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
        .onAppear(perform: refreshCounts)
        .onChange(of: smartBoardsEnabled) { refreshCounts() }
        .onChange(of: smartTopicsEnabled) { refreshCounts() }
        // Apple Intelligence may have been turned on or off in Settings meanwhile: the topic boards follow.
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshCounts() } }
        // A sort pass saves every 50 clips: one recount once the saves pause.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in refreshCounts() }
    }

    /// One `fetchCount` per board, leaving out the Mac's file links as History does. None while the setting is off.
    private func refreshCounts() {
        automatic = smartBoardsEnabled
            ? (try? SmartKinds.counts(in: modelContext, boards: SmartBoard.listed, excluding: [.fileURL])) ?? [] : []
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
    /// The board's clips only, fetched in the store, leaving out the Mac's file links as History does.
    @Query private var shown: [ClipboardItem]
    let board: SmartBoard

    init(board: SmartBoard) {
        self.board = board
        _shown = Query(filter: SmartKinds.predicate(for: board, excluding: [.fileURL]), sort: \.copiedAt, order: .reverse)
    }

    var body: some View {
        List {
            ScreenTitle(text: board.title).brandRow(top: 4, bottom: 9)
            ForEach(shown) { ClipRow(item: $0) }
            if shown.isEmpty { EmptyState(title: String(localized: "No clips yet"), symbol: "sparkles").brandRow() }
        }
        .brandList()
        .toolbarTitleDisplayMode(.inline)
    }
}
