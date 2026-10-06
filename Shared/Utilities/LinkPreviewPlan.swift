import CoreGraphics
import Foundation

/// The pure parts of link previews: which links are fetched next, which failures are retried, and the image a card
/// keeps. LinkPresentation itself lives in `LinkPreviewFetcher`, which only the apps compile.
enum LinkPreviewPlan {
    /// "Link previews". The App Group on iOS, like the secret settings, so the keyboard and widget read it too.
    static let enabledDefaultsKey = "linkPreviewsEnabled"
    static var isEnabled: Bool { SecretDetector.settings.object(forKey: enabledDefaultsKey) as? Bool ?? true }

    /// The longest side, in pixels, of the image a card keeps.
    static let targetPixelSize: CGFloat = 640
    static let jpegQuality: CGFloat = 0.7
    /// One fetch gives up after this long, and is retried by the next fill.
    static let timeout: TimeInterval = 10
    /// The fill pass looks at this many of the newest link clips, `batchSize` at a time.
    static let window = 300
    static let batchSize = 5

    struct Candidate: Sendable {
        let id: UUID
        let isLink: Bool
        let isSensitive: Bool
        let isDone: Bool
        let copiedAt: Date
        let url: String?
    }

    /// `retry`: offline or timed out, left for the next fill. `done`: final, stored with no preview.
    enum Outcome: Equatable, Sendable { case retry, done }

    /// The newest link clips not fetched yet, at most `limit`, among the `window` newest link clips. Never a secret, an
    /// id in `skipping` (failed earlier in this pass), or anything but an http(s) URL.
    static func nextBatch(clips: [Candidate], limit: Int = batchSize, window: Int = window,
                          skipping: Set<UUID>) -> [UUID] {
        clips.filter(\.isLink).sorted { $0.copiedAt > $1.copiedAt }.prefix(window)
            .filter { !$0.isDone && !$0.isSensitive && !skipping.contains($0.id) && fetchableURL($0.url) != nil }
            .prefix(limit).map(\.id)
    }

    /// The clip's text as an http(s) URL with a host. Nil for any other scheme, so a fetch never reads a local file.
    static func fetchableURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    static func outcome(for error: Error) -> Outcome {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorTimedOut),
             (NSURLErrorDomain, NSURLErrorNetworkConnectionLost):
            return .retry
        // `LPError.metadataFetchTimedOut`, by its domain and code, so the extensions never link LinkPresentation.
        case ("LPErrorDomain", 4): return .retry
        default: return .done
        }
    }

    /// The page's image as a card keeps it: a JPEG, at most `targetPixelSize` on its longest side, decoded by ImageIO
    /// at that size. Nil when the data is not an image.
    static func image(from data: Data) -> Data? {
        Thumbnail.jpeg(from: data, maxPixels: targetPixelSize, quality: jpegQuality)
    }
}

extension ClipboardItem {
    /// A link's fetched page title, for cards, search and the keyboard. Nil until fetched, with none, or for a secret.
    var linkPreviewTitle: String? {
        guard contentType == .url, !isSensitive, let linkTitle, !linkTitle.isEmpty else { return nil }
        return linkTitle
    }
}
