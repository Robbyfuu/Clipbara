#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Reads the iPhone pasteboard. Auto-capture reads each copy at most once: its `changeCount` is claimed in the
/// App Group defaults (`SharedDefaults.lastCapturedChangeCountKey`) before the read.
@MainActor
enum PasteboardCapture {
    /// The `changeCount` the last actual read saw, so a second read of the same copy (a second paste prompt) can be skipped.
    private(set) static var lastReadCount: Int?

    /// The copy no part of Copyd has handled yet, or nil. `changeCount`, `types` and the `has…` checks never show
    /// the paste prompt. The read may; a denied prompt returns nil, and the claimed count keeps it from asking again.
    /// With `readsImages` false (the keyboard: an image can exceed its ~50 MB budget) an image is neither read nor
    /// claimed, so the app captures it on its next open.
    /// A reboot resets `changeCount`, so one copy may be skipped; that is acceptable.
    static func newClip(readsImages: Bool = true) -> CapturedClip? {
        let pasteboard = UIPasteboard.general
        let count = pasteboard.changeCount
        let stored = SharedDefaults.store?.object(forKey: SharedDefaults.lastCapturedChangeCountKey) as? Int
        // Private and empty copies are claimed too, so they are never checked again.
        guard SharedDefaults.pasteboardAction(hasImages: pasteboard.hasImages, readsImages: readsImages,
                                              changeCount: count, stored: stored) == .claim,
              SharedDefaults.claimPasteboardChange(count),
              !pasteboard.contains(pasteboardTypes: ClipCapture.skippedPasteboardTypes),
              pasteboard.hasStrings || pasteboard.hasURLs || pasteboard.hasImages else { return nil }
        return read()
    }

    /// Unclaims the current copy after a failed inbox write, so the app saves it the next time it opens.
    static func leaveForApp() {
        SharedDefaults.store?.removeObject(forKey: SharedDefaults.lastCapturedChangeCountKey)
    }

    /// One read, so one paste prompt: an image (PNG first, else the first image type), otherwise the string.
    static func read() -> CapturedClip? {
        let pasteboard = UIPasteboard.general
        lastReadCount = pasteboard.changeCount
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
