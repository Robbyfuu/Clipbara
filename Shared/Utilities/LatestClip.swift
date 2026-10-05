import Foundation
import SwiftData

/// The clip that Shortcuts' "Copy last clip" copies and the Live Activity shows: the newest by `copiedAt`. File clips
/// are skipped, as in the keyboard: a Mac file path is useless on the iPhone, and copied files are shared from the app
/// instead. Secrets are skipped unless `includingSecrets` (Copy Last Clip, which pastes as a tap would).
enum LatestClip {
    @MainActor static func newest(in context: ModelContext, includingSecrets: Bool = false) throws -> ClipboardItem? {
        let fileRaw = ContentType.fileURL.rawValue, filesRaw = ContentType.files.rawValue
        let predicate = #Predicate<ClipboardItem> {
            $0.contentTypeRaw != fileRaw && $0.contentTypeRaw != filesRaw && (includingSecrets || $0.isSensitive == false)
        }
        var fetch = FetchDescriptor(predicate: predicate, sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        fetch.fetchLimit = 1
        return try context.fetch(fetch).first
    }
}
