#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Reads the iPhone pasteboard. Auto-capture reads each copy at most once: its `changeCount` is claimed in the
/// App Group defaults (`SharedDefaults.lastCapturedChangeCountKey`) before the read.
@MainActor
enum PasteboardCapture {
    /// The copy no part of Copyd has handled yet, or nil. `changeCount`, `types` and the `has…` checks never show
    /// the paste prompt. The read may; a denied prompt returns nil, and the claimed count keeps it from asking again.
    static func newClip() -> CapturedClip? {
        let pasteboard = UIPasteboard.general
        // Private and empty copies are claimed too, so they are never checked again.
        guard SharedDefaults.claimPasteboardChange(pasteboard.changeCount),
              !pasteboard.contains(pasteboardTypes: ClipCapture.skippedPasteboardTypes),
              pasteboard.hasStrings || pasteboard.hasURLs || pasteboard.hasImages else { return nil }
        return read()
    }

    /// One read, so one paste prompt: an image (PNG first, else the first image type), otherwise the string.
    static func read() -> CapturedClip? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.hasImages else {
            return (pasteboard.string ?? pasteboard.url?.absoluteString).flatMap(ClipCapture.text)
        }
        let png = UTType.png.identifier
        let type = pasteboard.types.contains(png) ? png : pasteboard.types.first { UTType($0)?.conforms(to: .image) == true }
        return type.flatMap { pasteboard.data(forPasteboardType: $0) }.flatMap(ClipCapture.image)
    }

    /// Call after every write Copyd makes to the pasteboard, so its own copy is never captured back.
    static func markHandled() {
        SharedDefaults.claimPasteboardChange(UIPasteboard.general.changeCount)
    }
}
#endif
