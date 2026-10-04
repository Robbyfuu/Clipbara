import Foundation
#if os(iOS)
import ActivityKit
#endif

/// The Lock Screen and Dynamic Island activity that shows the newest clip. The app and `CopydWidget` both compile it;
/// the state is plain `Codable` on every platform so the Mac test target checks it.
struct LatestClipActivity {
    struct ContentState: Codable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable { case text, link, image, color }

        /// In Unicode scalars, which bound the encoded bytes (4 each at most); a Character has no such bound.
        static let previewLimit = 120
        /// ActivityKit drops an update whose encoded state passes 4 KB; this leaves room for its own overhead.
        static let byteBudget = 3_072
        /// Text this long or longer reads as text without the link check, which runs on every save.
        static let linkCheckLimit = 2_048

        /// `last` when it already shows this clip at this copy time, else a new state. Every save in the app asks,
        /// and building one runs the link check and a JPEG encode.
        static func make(for item: ClipboardItem, reusing last: Self?) -> Self {
            if let last, last.clipID == item.id, last.copiedAt == item.copiedAt { return last }
            return Self(item)
        }

        var clipID: UUID
        var kind: Kind
        var preview: String
        var source: String?
        var copiedAt: Date
        /// About 64 px, images only. Left out when it would push the state past `byteBudget`.
        var thumbnail: Data?

        init(_ item: ClipboardItem) {
            let type = item.contentType
            let text = item.textContent ?? ""
            clipID = item.id
            kind = switch type {
            case .image: .image
            case .color: .color
            case .url: .link
            // `prefix(n).count < n` walks at most n characters, where `count` would walk the whole clip.
            default: text.prefix(Self.linkCheckLimit).count < Self.linkCheckLimit && LinkParts.bareLink(text) != nil ? .link : .text
            }
            let line = ArrivalNotice.preview(type: type, text: text).unicodeScalars
            preview = String(String.UnicodeScalarView(line.prefix(Self.previewLimit)))
            source = item.sourceAppName
            copiedAt = item.copiedAt
            thumbnail = kind == .image ? item.thumbnailData.flatMap { Thumbnail.jpeg(from: $0, maxPixels: 64, quality: 0.6) } : nil
            if encodedSize > Self.byteBudget { thumbnail = nil }  // a busy image; the views show the photo symbol
        }

        /// ActivityKit's own encoding is private; JSON, with the thumbnail in base64, is the closest stand-in.
        var encodedSize: Int { (try? JSONEncoder().encode(self).count) ?? .max }
    }
}

#if os(iOS)
extension LatestClipActivity: ActivityAttributes {}
#endif
