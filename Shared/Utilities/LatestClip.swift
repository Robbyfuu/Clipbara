import Foundation
import SwiftData

/// The clip that Shortcuts' "Copy last clip" copies: the newest by `copiedAt`. File clips are skipped, as in the
/// keyboard, because a Mac file path is useless on the iPhone.
enum LatestClip {
    @MainActor static func newest(in context: ModelContext) throws -> ClipboardItem? {
        let fileRaw = ContentType.fileURL.rawValue
        var fetch = FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.contentTypeRaw != fileRaw },
                                                   sortBy: [SortDescriptor(\.copiedAt, order: .reverse)])
        fetch.fetchLimit = 1
        return try context.fetch(fetch).first
    }
}
