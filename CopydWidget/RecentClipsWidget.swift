import SwiftData
import SwiftUI
import WidgetKit

@main
struct RecentClipsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecentClips", provider: RecentClipsProvider()) { RecentClipsEntryView(entry: $0) }
            .configurationDisplayName("Recent clips")
            .description("Your latest clips. Tap one to copy it.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct RecentClipsEntry: TimelineEntry {
    let date: Date
    let state: RecentClipsState
}

struct RecentClipsProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentClipsEntry {
        RecentClipsEntry(date: .now, state: .clips([KeyboardClip(
            id: UUID(), contentType: .plainText, preview: String(localized: "Your latest clip"), thumbnail: nil,
            isPinned: false, copiedAt: .now, textByteCount: 0, sourceAppName: "Copyd")]))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (RecentClipsEntry) -> Void) {
        Task { @MainActor in completion(Self.entry()) }
    }

    /// One entry and no schedule: the app reloads the widget after every save and every applied sync change.
    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<RecentClipsEntry>) -> Void) {
        Task { @MainActor in completion(Timeline(entries: [Self.entry()], policy: .never)) }
    }

    /// Order matters: the store file first (a fresh install has none), then open read-only and fetch.
    @MainActor private static func entry() -> RecentClipsEntry {
        guard let group = SharedStore.groupContainer, SharedStore.storeExists(groupContainer: group) else {
            return RecentClipsEntry(date: .now, state: .noStore)
        }
        do {
            let container = try ModelContainer(
                for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
                configurations: ModelConfiguration(
                    url: SharedStore.url(groupContainer: group), allowsSave: false, cloudKitDatabase: .none))
            return RecentClipsEntry(date: .now, state: .load(ModelContext(container)))
        } catch {
            return RecentClipsEntry(date: .now, state: .error)
        }
    }
}

struct RecentClipsEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentClipsEntry

    var body: some View {
        // Small and the Lock Screen have room for one clip, so the whole widget copies it.
        let url = entry.state.clips.first.map { QuickRoute.copyURL($0.id) }
        switch family {
        case .systemMedium:
            RecentClipsMedium(state: entry.state, now: entry.date)
                .containerBackground(for: .widget) { DesignTokens.Brand.shelf }
        case .accessoryRectangular:
            RecentClipsAccessory(state: entry.state, now: entry.date)
                .widgetURL(url)
                .containerBackground(for: .widget) { Color.clear }
        default:
            RecentClipsSmall(state: entry.state, now: entry.date)
                .widgetURL(url)
                .containerBackground(for: .widget) { DesignTokens.Brand.shelf }
        }
    }
}
