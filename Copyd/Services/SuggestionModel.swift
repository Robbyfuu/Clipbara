import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Reorders the habit's suggestions with the on-device Apple Intelligence model (macOS 26+). The panel never waits
/// for it: it shows the habit order, and `rerank` hands back a new order only when one arrives in time and is valid.
@MainActor
final class SuggestionModel {
    /// "Use Apple Intelligence" in General, under "Show suggestions". On by default.
    static let enabledDefaultsKey = "useAppleIntelligence"
    static let timeout: Duration = .milliseconds(600)

    /// Apple Intelligence is on and its model is ready. Always false before macOS 26.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.availability == .available }
        #endif
        return false
    }

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true) && isAvailable
    }

    private static let instructions = """
        You help a clipboard manager suggest clips. Pick what the user most likely pastes next in this app, using \
        the app's purpose and the paste history. Prefer content that fits the app, for example commands in a \
        terminal, links in a browser, addresses and emails in Mail. Never invent: answer only with indices from the \
        list, at most 3, best first.
        """
    private static let log = Logger(subsystem: "com.robbyfuu.copyd", category: "Suggestions")

    /// A `LanguageModelSession` on macOS 26+, typed `Any` so this class still loads on macOS 14. It serves one
    /// request: a session keeps every prompt in its transcript, so a reused one would soon fill its context window.
    private var session: Any?
    private var request: Task<Void, Never>?

    /// On panel open: loads the model ahead of the request.
    func prewarm() {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), Self.isEnabled else { return }
        warmSession().prewarm()
        #endif
    }

    /// Stops a request whose panel is gone or replaced; its answer is dropped.
    func cancel() {
        request?.cancel()
        request = nil
    }

    /// Asks the model to reorder `clips`, the habit's top 15 in order. `apply` gets the new top 3 only if the answer
    /// arrives within 600 ms and keeps at least one valid index. Reads only each clip's type and text, never
    /// `rawData`; file clips never reach here (they are not candidates).
    func rerank(_ clips: [ClipboardItem], pastedHere: [ClipboardItem], appName: String, bundleID: String,
                apply: @escaping @MainActor ([UUID]) -> Void) {
        cancel()
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), Self.isEnabled, clips.count > 1 else { return }
        let habit = clips.map(\.id), historyCount = pastedHere.count
        let prompt = Self.prompt(clips, pastedHere: pastedHere, appName: appName, bundleID: bundleID)
        let session = warmSession()
        self.session = nil
        request = Task {
            let start = ContinuousClock.now
            let indices = await SuggestionPicks.firstWithin(timeout: Self.timeout) {
                try await session.respond(to: prompt, generating: Picks.self,
                                          options: GenerationOptions(samplingMode: .greedy)).content.indices
            }
            let order = indices.flatMap { SuggestionPicks.reorder($0, of: habit) }
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "CopydLogSuggestionRerank") {
                let valid = indices.map { SuggestionPicks.validate(indices: $0, count: habit.count) }
                Self.log.notice("""
                    Rerank: \(habit.count) clips, \(historyCount) pasted here, \(prompt.count) prompt chars, \
                    \(Int((ContinuousClock.now - start) / .milliseconds(1))) ms, \
                    model \(indices.map { "\($0)" } ?? "no answer", privacy: .public), \
                    valid \(valid.map { "\($0)" } ?? "-", privacy: .public), cancelled \(Task.isCancelled)
                    """)
            }
            #endif
            guard !Task.isCancelled, let order else { return }
            apply(order)
        }
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    @Generable
    struct Picks {
        @Guide(description: "Indices of the clips from the list, best first", .maximumCount(3))
        var indices: [Int]
    }

    @available(macOS 26, *)
    private func warmSession() -> LanguageModelSession {
        if let session = session as? LanguageModelSession { return session }
        let session = LanguageModelSession(instructions: Self.instructions)
        self.session = session
        return session
    }

    /// The app, the types it gets most, then each clip as `index. [type] preview`. No clip text beyond 120 characters.
    private static func prompt(_ clips: [ClipboardItem], pastedHere: [ClipboardItem], appName: String,
                               bundleID: String) -> String {
        let history = pastedHere.map { item in
            clips.firstIndex { $0.id == item.id }.map { "\($0) (\(item.contentTypeRaw))" } ?? item.contentTypeRaw
        }
        let list = clips.enumerated().map { "\($0.offset). [\($0.element.contentTypeRaw)] \(SuggestionPicks.preview($0.element.textContent))" }
        return """
            App: \(appName) (\(bundleID))
            Most pasted in this app: \(history.isEmpty ? "nothing yet" : history.joined(separator: ", "))
            Clips:
            \(list.joined(separator: "\n"))
            """
    }
    #endif
}
