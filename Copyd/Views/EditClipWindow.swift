import AppKit
import SwiftData
import SwiftUI

/// "Edit clip": a normal titled Copyd window with a text editor, Save and Cancel. It opens after the panel hides, so it
/// is a titled window opened after the panel and the panel's focus hand-back leaves it in front. Closing it hands focus
/// back to the app the panel opened over: Copyd would otherwise stay active with no window, the next panel would open
/// over Copyd, and its pick would only copy.
@MainActor
final class EditClipWindowController: NSObject, NSWindowDelegate {
    static let shared = EditClipWindowController()

    private var window: NSWindow?
    private var returnApp: NSRunningApplication?

    /// A second ⌘E replaces the clip being edited, unsaved text included, in the same window. A panel opened over this
    /// window opened over Copyd: focus still goes back to the first app.
    func show(_ item: ClipboardItem, in context: ModelContext, returnTo app: NSRunningApplication?) {
        if let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier { returnApp = app }
        let editor = EditClipView(text: item.textContent ?? "") { [weak self] text in
            // The sweep or a sync may have deleted the clip meanwhile.
            if let text, !item.isDeleted, item.modelContext != nil {
                item.saveEdit(text, in: context)
            }
            self?.window?.close()
        }
        let hosting = NSHostingView(rootView: editor)
        hosting.sizingOptions = [.minSize]
        let window = self.window ?? makeWindow()
        window.contentView = hosting
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = String(localized: "Edit clip")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        let app = returnApp
        returnApp = nil
        guard NSApp.isActive, let app, !app.isTerminated else { return }
        _ = app.activate(options: [])
    }
}

private struct EditClipView: View {
    @State var text: String
    /// The text to save, or nil for Cancel.
    let onFinish: (String?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.Brand.ink)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(DesignTokens.Brand.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesignTokens.Brand.line, lineWidth: 1))
                .focused($focused)
            HStack(spacing: 8) {
                Button("Cancel") { onFinish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button { onFinish(text) } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.Brand.onButter)
                        .padding(.horizontal, 16)
                        .frame(height: 28)
                }
                .buttonStyle(ButterButtonStyle())
                // Return types a new line; ⌘Return saves.
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.isEmpty)
                .opacity(text.isEmpty ? 0.5 : 1)
                .help(Text(verbatim: "⌘↩"))
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 220)
        .background(DesignTokens.Brand.shelf)
        .onAppear { focused = true }
    }
}
