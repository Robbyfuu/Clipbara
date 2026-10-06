import AppIntents

// These intents live in the app target, so they run in the app's process and use `AppModel.shared`'s main
// context: the context the sync tracker observes, so their saves upload like any other local save.
// `SaveClipboardIntent` and `OpenSearchIntent` are in `OpenAppIntents.swift`, shared with the widget extension.

/// Silent capture: Shortcuts' own "Get Clipboard" feeds the text in, so the app never reads the pasteboard.
struct SaveTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Text to Copyd"

    @Parameter(title: "Text")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog: IntentDialog = switch SaveText.save(text: text, in: AppModel.shared.container.mainContext, now: Date()) {
        case .saved: "Saved"
        case .duplicate: "Already saved"
        case .empty: "Nothing to save"
        }
        return .result(dialog: dialog)
    }
}

/// Copies the newest clip and also returns it, so a shortcut can use it without reading the pasteboard. A secret is
/// returned masked, as rows show it; the pasteboard still gets the real value.
struct CopyLatestClipIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy Latest Clip"

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = AppModel.shared
        // A secret copies as a tap would; only displays leave it out.
        guard let item = try LatestClip.newest(in: model.container.mainContext, includingSecrets: true), model.copy(item) else {
            throw NoClipError()
        }
        return .result(value: item.contentType == .image ? "Image" : item.secretMask ?? item.textContent ?? "")
    }
}

private struct NoClipError: Error, CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { "No clip to copy" }
}

struct CopydShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SaveClipboardIntent(), phrases: ["Save clipboard in \(.applicationName)"],
                    shortTitle: "Save Clipboard", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: CopyLatestClipIntent(), phrases: ["Copy last clip from \(.applicationName)"],
                    shortTitle: "Copy Last Clip", systemImageName: "doc.on.doc")
        AppShortcut(intent: SaveTextIntent(), phrases: ["Save text to \(.applicationName)"],
                    shortTitle: "Save Text", systemImageName: "text.badge.plus")
    }
}
