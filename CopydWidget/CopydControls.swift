import AppIntents
import SwiftUI
import WidgetKit

// Control Center and Action button controls. Both open the app, which reads the pasteboard or focuses search.

@available(iOS 18, *)
struct SaveClipboardControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.robbyfuu.copyd.control.save") {
            ControlWidgetButton(action: SaveClipboardIntent()) {
                Label("Save Clipboard", systemImage: "doc.on.clipboard")
            }
        }
        .displayName("Save Clipboard")
    }
}

@available(iOS 18, *)
struct SearchControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.robbyfuu.copyd.control.search") {
            ControlWidgetButton(action: OpenSearchIntent()) {
                Label("Search Copyd", systemImage: "magnifyingglass")
            }
        }
        .displayName("Search Copyd")
    }
}

/// Lock Screen circular: one tap saves the clipboard. iOS asks to unlock before it opens the app.
struct LockScreenSaveWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SaveClipboard", provider: LockScreenSaveProvider()) { _ in
            LockScreenSaveView().containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Save")
        .description("Save your clipboard to Copyd.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// The button never changes, so one entry and no schedule.
struct LockScreenSaveProvider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (SimpleEntry) -> Void) {
        completion(SimpleEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SimpleEntry>) -> Void) {
        completion(Timeline(entries: [SimpleEntry(date: .now)], policy: .never))
    }

    struct SimpleEntry: TimelineEntry {
        let date: Date
    }
}
