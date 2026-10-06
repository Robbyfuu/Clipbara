import LinkPresentation
import SwiftData
import XCTest

/// Review focus 1 and 2: a secret is never fetched, and a preview is fetched for the newest links, a few at a time.
final class LinkPreviewPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func clip(_ minutesAgo: Int, link: Bool = true, secret: Bool = false, done: Bool = false,
                      url: String? = "https://copyd.app/a") -> LinkPreviewPlan.Candidate {
        LinkPreviewPlan.Candidate(id: UUID(), isLink: link, isSensitive: secret, isDone: done,
                                  copiedAt: now.addingTimeInterval(TimeInterval(-60 * minutesAgo)), url: url)
    }

    func testBatchIsTheNewestLinksNotYetFetched() {
        let text = clip(0, link: false), a = clip(1), done = clip(2, done: true), b = clip(3), c = clip(4)
        XCTAssertEqual(LinkPreviewPlan.nextBatch(clips: [c, done, text, b, a], limit: 2, skipping: []), [a.id, b.id])
    }

    func testBatchHoldsFiveByDefault() {
        let clips = (0..<12).map { clip($0) }
        XCTAssertEqual(LinkPreviewPlan.nextBatch(clips: clips.shuffled(), skipping: []), clips.prefix(5).map(\.id))
    }

    /// The window counts link clips only: newer text clips never push a link out of it.
    func testWindowCoversTheNewest300Links() {
        let texts = (0..<50).map { clip($0, link: false) }
        let fetched = (50..<349).map { clip($0, done: true) }
        let last = clip(349), outside = clip(350)
        XCTAssertEqual(LinkPreviewPlan.nextBatch(clips: texts + fetched + [last, outside], skipping: []), [last.id])
        XCTAssertEqual(LinkPreviewPlan.nextBatch(clips: fetched + [last, outside], window: 299, skipping: []), [])
    }

    func testSecretsAreNeverFetched() {
        let secret = clip(0, secret: true), link = clip(1)
        XCTAssertEqual(LinkPreviewPlan.nextBatch(clips: [secret, link], skipping: []), [link.id])
        XCTAssertEqual(LinkPreviewPlan.nextBatch(clips: [secret], skipping: []), [])
    }

    func testOnlyHttpAndHttpsURLsAreFetched() {
        let https = clip(0), http = clip(1, url: "http://copyd.app"), upper = clip(2, url: "HTTPS://copyd.app")
        let others = ["ftp://copyd.app/f", "file:///etc/hosts", "copyd://search", "mailto:a@b.c", "javascript:alert(1)",
                      "https://", "not a url", ""].enumerated().map { clip(3 + $0.offset, url: $0.element) }
        let none = clip(20, url: nil)
        XCTAssertEqual(LinkPreviewPlan.nextBatch(clips: [https, http, upper] + others + [none], limit: 20, skipping: []),
                       [https.id, http.id, upper.id])
    }

    /// A link that failed to fetch in this pass is never fetched again by it.
    func testSkippedIdsAreLeftOut() {
        let a = clip(0), b = clip(1), c = clip(2)
        XCTAssertEqual(LinkPreviewPlan.nextBatch(clips: [a, b, c], limit: 2, skipping: [a.id]), [b.id, c.id])
    }

    func testOfflineAndTimeoutAreRetried() {
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost] {
            XCTAssertEqual(LinkPreviewPlan.outcome(for: NSError(domain: NSURLErrorDomain, code: code)), .retry, "\(code)")
        }
        XCTAssertEqual(LinkPreviewPlan.outcome(for: LPError(.metadataFetchTimedOut)), .retry)
    }

    /// A fetch cut off by `stop()` or the system is not an answer about the link: tried again by the next fill.
    func testCancellationIsRetried() {
        XCTAssertEqual(LinkPreviewPlan.outcome(for: CancellationError()), .retry)
        XCTAssertEqual(LinkPreviewPlan.outcome(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)), .retry)
        XCTAssertEqual(LinkPreviewPlan.outcome(for: LPError(.metadataFetchCancelled)), .retry)
    }

    /// LinkPresentation wraps the network error: an offline failure is retried, a bare failure is final.
    func testUnderlyingErrorDecides() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertEqual(LinkPreviewPlan.outcome(for: LPError(.metadataFetchFailed, userInfo: [NSUnderlyingErrorKey: offline])),
                       .retry)
        XCTAssertEqual(LinkPreviewPlan.outcome(for: LPError(.metadataFetchFailed)), .done)
        let notFound = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        XCTAssertEqual(LinkPreviewPlan.outcome(for: LPError(.metadataFetchFailed, userInfo: [NSUnderlyingErrorKey: notFound])),
                       .done)
    }

    /// Rulings E4 and E6: a single-use link (sign-in, reset, verify, invite, unsubscribe) is never fetched: the fetch
    /// could use it up. Query names and path segments match by substring, and a fragment holding a value is a token.
    func testSingleUseLinksAreNeverFetched() {
        for url in ["https://example.com/blog?page=2", "https://www.apple.com", "https://github.com/org/repo",
                    "https://news.ycombinator.com/item?id=1", "https://github.com/apple/swift/blob/main/README.md",
                    "https://example.com/search?q=token", "https://example.com/?keyboard=1", "https://example.com/docs#install"] {
            XCTAssertNotNil(LinkPreviewPlan.fetchableURL(url), url)
        }
        for url in ["https://app.example.com/login?token=abc", "https://example.com/a?TOKEN=abc", "https://x.com/?otp=123456",
                    "https://x.com/cb?state=1&code=abc", "https://x.com/f?sig=1", "https://x.com/f?Signature=1",
                    "https://x.com/?reset=1", "https://x.com/?verify=1", "https://x.com/?verification=1",
                    "https://x.com/?magic=1", "https://x.com/?auth=1", "https://x.com/?password=p", "https://x.com/?passwd=p",
                    "https://x.com/?session=s", "https://x.com/?ticket=t", "https://x.com/?nonce=n", "https://x.com/?invite=i",
                    "https://x.com/?confirm=1",
                    // E6: names that only contain a word
                    "https://x.com/cb?access_token=abc", "https://x.com/?reset_password_token=abc",
                    "https://x.com/?confirmation_token=abc", "https://x.com/cb?id_token=abc",
                    "https://x.firebaseapp.com/__/auth/action?mode=resetPassword&oobCode=x",
                    // E6: a token in the fragment
                    "https://x.com/cb#access_token=abc",
                    // path segments
                    "https://x.com/reset-password/abc", "https://x.com/account/Verify?id=1", "https://x.com/magic-link/xyz",
                    "https://x.com/email/confirm", "https://x.com/unsubscribe/123", "https://x.com/reset/MQ/abc-123/",
                    "https://x.com/users/confirmation?x=1", "https://x.com/verify-email-guide", "https://x.com/activate/abc",
                    "https://x.com/team/invite/abc"] {
            XCTAssertNil(LinkPreviewPlan.fetchableURL(url), url)
        }
    }

    /// Ruling E6: a link to this device, the local network or a private address is never fetched: the fetch could act
    /// on a router, a printer or a dev server.
    func testLocalAndPrivateHostsAreNeverFetched() {
        for url in ["http://localhost:3000/", "http://LOCALHOST./a", "http://dev.localhost/", "http://printer.local/",
                    "http://router.lan", "http://nas.home/", "http://grafana.internal/d", "http://intranet/",
                    "http://127.0.0.1:8080/", "http://127.1/", "http://2130706433/", "http://0.0.0.0/",
                    "http://10.0.0.1/", "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.1.1/",
                    "http://169.254.169.254/latest/meta-data", "http://100.64.0.1/", "http://100.127.255.255/",
                    "http://[::1]/", "http://[::]/", "http://[fe80::1]/", "http://[fe80::1%25en0]/", "http://[febf::1]/",
                    "http://[fc00::1]/", "http://[fd12:3456::1]/", "http://[::ffff:192.168.0.1]/"] {
            XCTAssertNil(LinkPreviewPlan.fetchableURL(url), url)
        }
        for url in ["http://172.32.0.1/", "http://172.15.0.1/", "http://100.63.0.1/", "http://100.128.0.1/",
                    "http://8.8.8.8/", "http://11.0.0.1/", "http://[2001:4860:4860::8888]/", "http://[fec0::1]/",
                    "https://local.example.com", "https://my.home.example.com", "https://example.co.uk"] {
            XCTAssertNotNil(LinkPreviewPlan.fetchableURL(url), url)
        }
    }

    /// Links never fetched (another scheme, or single use) are marked done at once, so no pass looks at them again.
    /// Never a secret, a done clip, or one outside the window.
    func testNeverFetchedLinksAreTheUnfetchableOnes() {
        let web = clip(0), once = clip(1, url: "https://x.com/login?token=abc"), ftp = clip(2, url: "ftp://x.com/f")
        let secret = clip(3, secret: true, url: "https://x.com/login?token=abc")
        let done = clip(4, done: true, url: "ftp://x.com/g"), text = clip(5, link: false, url: "not a url")
        XCTAssertEqual(LinkPreviewPlan.neverFetched(clips: [done, secret, ftp, text, once, web]), [once.id, ftp.id])
        XCTAssertEqual(LinkPreviewPlan.neverFetched(clips: [web, once, ftp], window: 2), [once.id])
    }

    /// No metadata, an HTTP error or a bad host is final: a dead link is never fetched again.
    func testOtherFailuresAreDone() {
        XCTAssertEqual(LinkPreviewPlan.outcome(for: LPError(.metadataFetchFailed)), .done)
        XCTAssertEqual(LinkPreviewPlan.outcome(for: LPError(.unknown)), .done)
        XCTAssertEqual(LinkPreviewPlan.outcome(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)), .done)
        XCTAssertEqual(LinkPreviewPlan.outcome(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)), .done)
        XCTAssertEqual(LinkPreviewPlan.outcome(for: CocoaError(.fileReadUnknown)), .done)
    }

    func testConstants() {
        XCTAssertEqual(LinkPreviewPlan.targetPixelSize, 640)
        XCTAssertEqual(LinkPreviewPlan.jpegQuality, 0.7)
        XCTAssertEqual(LinkPreviewPlan.timeout, 10)
        XCTAssertEqual(LinkPreviewPlan.enabledDefaultsKey, "linkPreviewsEnabled")
    }

    /// The image a card shows: a JPEG no larger than 640 px on its longest side.
    func testPreviewImageIsA640PixelJPEG() throws {
        let jpeg = try XCTUnwrap(LinkPreviewPlan.image(from: OCRImage.png(width: 2400, height: 1200)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual([image.width, image.height], [640, 320])
        XCTAssertNil(LinkPreviewPlan.image(from: Data("not an image".utf8)))
    }

    /// The fetched title, for cards, search and the keyboard: never a secret's, never an empty one.
    @MainActor
    func testPreviewTitleIsANonSecretLinksNonEmptyTitle() throws {
        let container = try ModelContainer(for: ClipboardItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let link = ClipboardItem(contentType: .url, rawData: Data(), textContent: "https://apple.com", contentHash: "l")
        container.mainContext.insert(link)
        XCTAssertNil(link.linkPreviewTitle, "not fetched yet")
        link.linkTitle = ""
        XCTAssertNil(link.linkPreviewTitle)
        link.linkTitle = "Apple"
        XCTAssertEqual(link.linkPreviewTitle, "Apple")
        link.isSensitive = true
        XCTAssertNil(link.linkPreviewTitle)
    }
}

@MainActor
final class LinkPreviewQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var saves: [Set<UUID>] = []

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        saves = []
    }

    @discardableResult
    private func insert(_ text: String, type: ContentType = .url, secret: Bool = false) throws -> ClipboardItem {
        let item = ClipboardItem(contentType: type, rawData: Data(text.utf8), textContent: text, contentHash: UUID().uuidString)
        item.isSensitive = secret
        container.mainContext.insert(item)
        try container.mainContext.save()
        return item
    }

    private func makeQueue(enabled: Bool = true,
                           fetch: @escaping @Sendable (URL) async -> LinkPreviewFetcher.Outcome) -> LinkPreviewQueue {
        LinkPreviewQueue(container: container, isEnabled: { enabled }, fetch: fetch) { [unowned self] ids in
            saves.append(ids)
            try? container.mainContext.save()
        }
    }

    private func finish(_ queue: LinkPreviewQueue) async {
        while let task = queue.task { await task.value }
    }

    func testFillStoresTitleAndImageAndMarksEachOneDone() async throws {
        let apple = try insert("https://www.apple.com")
        let dead = try insert("https://copyd.app/gone")
        let text = try insert("https://not.a.link.clip", type: .plainText)
        let image = Data([0xFF, 0xD8])
        let queue = makeQueue { url in
            url.host == "www.apple.com" ? .preview(title: "Apple", image: image) : .preview(title: nil, image: nil)
        }
        queue.fill()
        await finish(queue)
        XCTAssertEqual(apple.linkTitle, "Apple")
        XCTAssertEqual(apple.linkImageData, image)
        XCTAssertTrue(apple.linkPreviewDone)
        XCTAssertNil(dead.linkTitle)
        XCTAssertNil(dead.linkImageData)
        XCTAssertTrue(dead.linkPreviewDone, "a dead link is never fetched again")
        XCTAssertFalse(text.linkPreviewDone)
        XCTAssertEqual(saves, [[apple.id, dead.id]], "one batch, saved through the local-only save")
    }

    /// Offline or timed out: left for the next `fill`, and never fetched twice in one pass, even across batches.
    func testRetryIsFetchedByTheNextFillOnly() async throws {
        let others = try (1...6).map { try insert("https://copyd.app/\($0)") }
        let flaky = try insert("https://copyd.app/flaky")
        let fetches = Fetches()
        let offline = makeQueue { url in
            fetches.add(url)
            return url.lastPathComponent == "flaky" ? .retry : .preview(title: "ok", image: nil)
        }
        offline.fill()
        await finish(offline)
        XCTAssertFalse(flaky.linkPreviewDone)
        XCTAssertEqual(fetches.count(of: URL(string: "https://copyd.app/flaky")!), 1, "once per pass, not once per batch")
        XCTAssertTrue(others.allSatisfy(\.linkPreviewDone))

        let online = makeQueue { _ in .preview(title: "Flaky", image: nil) }
        online.fill()
        await finish(online)
        XCTAssertTrue(flaky.linkPreviewDone)
        XCTAssertEqual(flaky.linkTitle, "Flaky")
    }

    func testSecretsAreNeverFetched() async throws {
        let secret = try insert("https://copyd.app/reset?token=abc", secret: true)
        let fetches = Fetches()
        let queue = makeQueue { url in fetches.add(url); return .preview(title: "t", image: nil) }
        queue.fill()
        await finish(queue)
        XCTAssertEqual(fetches.all, [])
        XCTAssertFalse(secret.linkPreviewDone)
        XCTAssertNil(secret.linkTitle)
    }

    func testNothingIsFetchedWhileOff() async throws {
        let link = try insert("https://www.apple.com")
        let fetches = Fetches()
        let queue = makeQueue(enabled: false) { url in fetches.add(url); return .preview(title: "t", image: nil) }
        queue.fill()
        await finish(queue)
        XCTAssertNil(queue.task)
        XCTAssertEqual(fetches.all, [])
        XCTAssertFalse(link.linkPreviewDone)
    }

    /// The clip was edited to another link while its old one was fetched: the old page's preview is dropped.
    func testPreviewOfAnEditedLinkIsDropped() async throws {
        let link = try insert("https://copyd.app/old")
        let gate = Gate()
        let queue = makeQueue { _ in gate.enter(); return .preview(title: "Old page", image: nil) }
        queue.fill()
        guard await gate.waitUntilEntered() else { return XCTFail("never fetched") }
        XCTAssertTrue(link.saveEdit("https://copyd.app/new", in: container.mainContext, protects: false))
        queue.stop()
        gate.open()
        await finish(queue)
        XCTAssertNil(link.linkTitle)
        XCTAssertFalse(link.linkPreviewDone, "the new link is fetched by the next fill")
    }

    /// A user change still pending on the main context is saved first, by a save the sync tracker reports.
    func testPendingChangesAreSavedBeforeTheLocalOnlySave() async throws {
        let link = try insert("https://www.apple.com")
        let note = try insert("n", type: .plainText)
        let id = note.id
        var titleWasSaved: Bool?
        let queue = LinkPreviewQueue(container: container, isEnabled: { true },
                                     fetch: { _ in .preview(title: "Apple", image: nil) }) { [unowned self] _ in
            let fresh = try? ModelContext(container).fetch(FetchDescriptor<ClipboardItem>(predicate: #Predicate { $0.id == id })).first
            titleWasSaved = fresh?.userTitle == "renamed"
            try? container.mainContext.save()
        }
        queue.fill()
        note.userTitle = "renamed"  // unsaved when the pass writes
        await finish(queue)
        XCTAssertTrue(link.linkPreviewDone)
        XCTAssertEqual(titleWasSaved, true)
    }

    /// `stop()` mid-fetch: whatever the fetch returns, it was cut off, so the link stays for the next fill.
    func testStoppedFetchIsNeverMarkedDone() async throws {
        let link = try insert("https://www.apple.com")
        let gate = Gate()
        let queue = makeQueue { _ in gate.enter(); return .preview(title: nil, image: nil) }
        queue.fill()
        guard await gate.waitUntilEntered() else { return XCTFail("never fetched") }
        queue.stop()
        gate.open()
        await finish(queue)
        XCTAssertFalse(link.linkPreviewDone)
        XCTAssertNil(link.linkTitle)
        XCTAssertEqual(saves, [])
    }

    /// A single-use or local link is marked done with no preview, never fetched.
    func testSingleUseLinkIsDoneWithoutAFetch() async throws {
        let once = try insert("https://app.example.com/login?token=abc")
        let lan = try insert("http://192.168.1.1/")
        let web = try insert("https://www.apple.com")
        let fetches = Fetches()
        let queue = makeQueue { url in fetches.add(url); return .preview(title: "Apple", image: nil) }
        queue.fill()
        await finish(queue)
        XCTAssertEqual(fetches.all, [URL(string: "https://www.apple.com")!])
        XCTAssertTrue(once.linkPreviewDone)
        XCTAssertNil(once.linkTitle)
        XCTAssertTrue(lan.linkPreviewDone)
        XCTAssertNil(lan.linkTitle)
        XCTAssertEqual(web.linkTitle, "Apple")
    }

    func testFillWhileAPassRunsNeverStartsASecond() async throws {
        try insert("https://www.apple.com")
        let queue = makeQueue { _ in .preview(title: "Apple", image: nil) }
        queue.fill()
        let first = queue.task
        queue.fill()
        XCTAssertNotNil(first)
        XCTAssertEqual(queue.task, first)
        await queue.task?.value
        XCTAssertEqual(saves.count, 1)
    }
}

/// The fetcher's inputs, from any thread.
private final class Fetches: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var all: [URL] { lock.withLock { urls } }
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    func count(of url: URL) -> Int { lock.withLock { urls.filter { $0 == url }.count } }
}

/// Holds the fetcher inside its first fetch until `open`, so a test can change the clip mid-fetch.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private let released = DispatchSemaphore(value: 0)
    private var count = 0
    private var isOpen = false

    var entries: Int { lock.withLock { count } }

    func enter() {
        let wait = lock.withLock { count += 1; return !isOpen }
        if wait { released.wait() }
    }

    func open() {
        lock.withLock { isOpen = true }
        released.signal()
    }

    /// False after 5 s with no fetch, so a broken queue fails the test instead of hanging it.
    func waitUntilEntered() async -> Bool {
        for _ in 0..<1000 where entries == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        return entries > 0
    }
}
