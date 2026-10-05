import SwiftUI
import SwiftData

struct HistoryView: View {
    private enum Filter: CaseIterable, Identifiable {
        case all, text, links, images
        var id: Self { self }
        var title: LocalizedStringResource {
            switch self {
            case .all: "All"
            case .text: "Text"
            case .links: "Links"
            case .images: "Images"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Query(sort: \ClipboardItem.copiedAt, order: .reverse) private var items: [ClipboardItem]
    @State private var search = ""
    @State private var filter = Filter.all
    @FocusState private var searchFocused: Bool
    /// Set by the Search quick action; focuses the field once, then resets.
    @Binding var focusSearch: Bool
    var openSettings: () -> Void = {}

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
                || ((item.secretMask ?? item.textContent)?.localizedCaseInsensitiveContains(search) ?? false)
                || (item.userTitle?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    var body: some View {
        let shown = visible
        List {
            HStack {
                CopydWordmark(size: 28)
                Spacer(minLength: 12)
                syncChip
            }
            .brandRow(top: 4, bottom: 0)
            ScreenTitle(text: String(localized: "History")).brandRow(top: 14, bottom: 0)
            searchField.brandRow(top: 14, bottom: 0)
            pills.brandRow(top: 14, bottom: 9)
            ForEach(shown) { ClipRow(item: $0) }
            if shown.isEmpty {
                EmptyState(title: items.isEmpty ? String(localized: "No clips yet") : String(localized: "No results"),
                           symbol: "clipboard").brandRow()
            }
        }
        .brandList()
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: focusSearch, initial: true) { _, requested in
            guard requested else { return }
            focusSearch = false
            searchFocused = true
        }
    }

    private var syncChip: some View {
        Button(action: openSettings) {
            TimelineView(.everyMinute) { context in
                let (symbol, text) = syncLabel(now: context.date)
                HStack(spacing: 6) {
                    Image(systemName: symbol).accessibilityHidden(true)
                    Text(text).lineLimit(1)
                }
                .brandFont(13, .semibold, relativeTo: .footnote)
                .foregroundStyle(DesignTokens.Brand.ink)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(DesignTokens.Brand.butterSoft, in: Capsule())
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Settings")
    }

    private func syncLabel(now: Date) -> (String, String) {
        switch model.sync.status {
        case .upToDate(let date):
            ("checkmark.icloud", String(localized: "Synced \u{00b7} \(ClipAge.text(from: date, now: now))"))
        case .syncing: ("arrow.triangle.2.circlepath.icloud", String(localized: "Syncing\u{2026}"))
        case .accountUnavailable: ("person.icloud", String(localized: "Sign in to iCloud"))
        case .quotaExceeded: ("exclamationmark.icloud", String(localized: "iCloud full"))
        case .error: ("exclamationmark.icloud", String(localized: "Sync error"))
        case .off, .accountChanged: ("icloud.slash", String(localized: "Sync off"))
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .brandFont(16, .medium)
                .foregroundStyle(DesignTokens.Brand.ink2)
                .accessibilityHidden(true)
            TextField("Search clips", text: $search, prompt: Text("Search clips").foregroundStyle(DesignTokens.Brand.ink2))
                .brandFont(16)
                .foregroundStyle(DesignTokens.Brand.ink)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(DesignTokens.Brand.ink2)
                        .frame(minWidth: 32, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(DesignTokens.Brand.chip, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
    }

    private var pills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases) { option in
                    let active = option == filter
                    Button { filter = option } label: {
                        Text(option.title)
                            .brandFont(15, active ? .bold : .semibold, relativeTo: .subheadline)
                            .foregroundStyle(active ? DesignTokens.Brand.onButter : DesignTokens.Brand.ink2)
                            .padding(.horizontal, 16)
                            .frame(minHeight: 44)
                            .background(active ? DesignTokens.Brand.butter : DesignTokens.Brand.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(active ? Color.clear : DesignTokens.Brand.line, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
    }
}
