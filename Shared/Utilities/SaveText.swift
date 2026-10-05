import Foundation
import SwiftData

enum SaveOutcome: Equatable {
    case saved, duplicate, empty
}

/// Shortcuts' "Save text to Copyd": the same capture and 10 s duplicate rule as the clipboard save.
enum SaveText {
    /// Pass the app's main context: the sync tracker watches it, so the insert uploads.
    @MainActor static func save(text: String, in context: ModelContext, now: Date) -> SaveOutcome {
        guard let clip = ClipCapture.text(text) else { return .empty }
        // A failed check saves anyway: an extra row beats a lost clip.
        if (try? ClipCapture.isRecentDuplicate(hash: clip.contentHash, in: context, now: now)) == true {
            return .duplicate
        }
        let item = ClipboardItem(contentType: clip.contentType, rawData: clip.rawData, textContent: clip.textContent,
                                 sourceAppName: "Shortcuts", contentHash: clip.contentHash)
        item.copiedAt = now
        item.isSensitive = SecretDetector.flags(clip.textContent, type: clip.contentType)
        context.insert(item)
        try? context.save()
        return .saved
    }
}
