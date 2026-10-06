import CoreGraphics
import Foundation
import ImageIO

/// The pure parts of link previews: which links are fetched next, which failures are retried, and the image a card
/// keeps. LinkPresentation itself lives in `LinkPreviewFetcher`, which only the apps compile.
enum LinkPreviewPlan {
    /// "Link previews". The App Group on iOS, like the secret settings, so the keyboard and widget read it too.
    static let enabledDefaultsKey = "linkPreviewsEnabled"
    static var isEnabled: Bool { SecretDetector.settings.object(forKey: enabledDefaultsKey) as? Bool ?? true }

    /// The longest side, in pixels, of the image a card keeps.
    static let targetPixelSize: CGFloat = 640
    static let jpegQuality: CGFloat = 0.7
    /// A smaller image, on its longest side, is a site's icon: never kept.
    static let minPixelSize = 200
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

    /// `retry`: timed out or cut off, left for the next fill. `done`: final, stored with no preview. `offline`: no
    /// connection, so the pass ends and every link left waits for the next fill.
    enum Outcome: Equatable, Sendable { case retry, done, offline }

    /// The newest link clips not fetched yet, at most `limit`, among the `window` newest link clips. Never a secret, an
    /// id in `skipping` (failed earlier in this pass), or anything but an http(s) URL.
    static func nextBatch(clips: [Candidate], limit: Int = batchSize, window: Int = window,
                          skipping: Set<UUID>) -> [UUID] {
        clips.filter(\.isLink).sorted { $0.copiedAt > $1.copiedAt }.prefix(window)
            .filter { !$0.isDone && !$0.isSensitive && !skipping.contains($0.id) && fetchableURL($0.url) != nil }
            .prefix(limit).map(\.id)
    }

    /// Link clips among the `window` newest that no fetch will ever take: another scheme, or a single-use link. Marked
    /// done with no preview, so no pass looks at them again. Never a secret.
    static func neverFetched(clips: [Candidate], window: Int = window) -> [UUID] {
        clips.filter(\.isLink).sorted { $0.copiedAt > $1.copiedAt }.prefix(window)
            .filter { !$0.isDone && !$0.isSensitive && fetchableURL($0.url) == nil }
            .map(\.id)
    }

    /// Rulings E4 and E6: words in the query item names and path segments of sign-in, reset, verify, invite and
    /// unsubscribe links. Fetching one could use it up, or act on it. Matched as substrings of the lowercased name or
    /// segment, so `access_token` and `oobCode` match too.
    static let singleUseQueryWords = ["token", "code", "otp", "auth", "password", "passwd", "reset", "verif", "confirm",
                                      "magic", "invite", "nonce", "ticket", "session", "sig"]
    static let singleUsePathWords = ["reset", "verif", "confirm", "magic", "unsubscribe", "activate", "invite"]
    /// Ruling E6: names only the local network resolves.
    static let localHostSuffixes = [".local", ".lan", ".home", ".internal", ".localhost"]

    /// The clip's text as an http(s) URL with a host. Nil for any other scheme, so a fetch never reads a local file, for
    /// a single-use link (a fragment holding a value, like `#access_token=…`, is one), and for a local or private host.
    static func fetchableURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty, !isLocal(host: host) else { return nil }
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        func hasWord(_ words: [String], in parts: [String]) -> Bool {
            parts.contains { part in words.contains { part.lowercased().contains($0) } }
        }
        guard !hasWord(singleUseQueryWords, in: names), !hasWord(singleUsePathWords, in: url.pathComponents),
              url.fragment(percentEncoded: false)?.contains("=") != true else { return nil }
        return url
    }

    /// `localhost`, a single-label or local-network name, or a loopback, private, link-local or CGNAT address. IPv4
    /// is read the way the resolver reads it, so `127.1` and `2130706433` are loopback too.
    static func isLocal(host: String) -> Bool {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 { return isPrivate(v4: withUnsafeBytes(of: v4.s_addr) { Array($0) }) }
        var v6 = in6_addr()
        // A zone (`fe80::1%en0`) is only on link-local addresses.
        if inet_pton(AF_INET6, String(host.prefix { $0 != "%" }), &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            // ::ffff:a.b.c.d carries an IPv4 address.
            if b[..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF { return isPrivate(v4: Array(b[12...])) }
            let unspecifiedOrLoopback = b[..<15].allSatisfy { $0 == 0 } && b[15] <= 1
            return unspecifiedOrLoopback || (b[0] == 0xFE && b[1] & 0xC0 == 0x80) || b[0] & 0xFE == 0xFC  // fe80::/10, fc00::/7
        }
        return host == "localhost" || !host.contains(".") || localHostSuffixes.contains { host.hasSuffix($0) }
    }

    /// 0/8 (`0.0.0.0` reaches this device), 10/8, 127/8, 169.254/16, 172.16/12, 192.168/16 and 100.64/10, from the
    /// address's 4 bytes in network order.
    private static func isPrivate(v4 b: [UInt8]) -> Bool {
        [0, 10, 127].contains(b[0]) || (b[0] == 169 && b[1] == 254) || (b[0] == 172 && b[1] & 0xF0 == 16)
            || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] & 0xC0 == 64)
    }

    /// Offline is `offline`; timed out or cut off (`stop()`, the system) is `retry`, also when LinkPresentation wraps it.
    static func outcome(for error: Error) -> Outcome {
        if error is CancellationError { return .retry }
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet): return .offline
        case (NSURLErrorDomain, NSURLErrorTimedOut), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorCancelled):
            return .retry
        // `LPError.metadataFetchCancelled` and `.metadataFetchTimedOut`, by domain and code, so the extensions never
        // link LinkPresentation.
        case ("LPErrorDomain", 3), ("LPErrorDomain", 4): return .retry
        default:
            return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(outcome(for:)) ?? .done
        }
    }

    /// The page's image as a card keeps it: a JPEG, at most `targetPixelSize` on its longest side, decoded by ImageIO
    /// at that size. Nil when the data is not an image, or one under `minPixelSize`: a site's icon, so the card keeps
    /// the title only.
    static func image(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) >= minPixelSize else { return nil }
        return Thumbnail.jpeg(from: data, maxPixels: targetPixelSize, quality: jpegQuality)
    }
}

extension ClipboardItem {
    /// A link's fetched page title, for cards, search and the keyboard. Nil until fetched, with none, or for a secret.
    var linkPreviewTitle: String? {
        guard contentType == .url, !isSensitive, let linkTitle, !linkTitle.isEmpty else { return nil }
        return linkTitle
    }
}
