import AppIntents

// Intents that open Copyd and hand it a route. Controls and the Lock Screen widget run them, so this file is also
// compiled into the widget extension: the system opens the app only when the intent is a member of both targets.
// With `openAppWhenRun`, `perform` runs in the app's process. The widget build defines `WIDGET_EXTENSION`, where
// `AppModel` does not exist, so the body is compiled into the app only.
// The route never travels as a `copyd://` URL, so a web page cannot trigger a save (see `QuickRoute.allowsURL`).

/// iOS only lets the foreground app read the pasteboard, so this opens Copyd and hands the save to the
/// same route the Home Screen quick action uses. iOS shows its paste prompt.
struct SaveClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Clipboard"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        AppModel.shared.pendingRoute = .saveClipboard
        #endif
        return .result()
    }
}

/// Opens History with the search field focused.
struct OpenSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Copyd"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        AppModel.shared.pendingRoute = .search
        #endif
        return .result()
    }
}
