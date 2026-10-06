import SwiftData
import XCTest

/// Review focus 4: the topic model never receives secrets, images or files, and a failure retries.
final class TopicPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ type: ContentType, _ minutesAgo: Int, secret: Bool = false,
                           done: Bool = false) -> TopicPlan.Candidate {
        TopicPlan.Candidate(id: UUID(), contentType: type, isSensitive: secret, isDone: done,
                            copiedAt: now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    }

    func testBatchSkipsSecretsImagesAndFiles() {
        let text = candidate(.plainText, 0), link = candidate(.url, 1), rich = candidate(.richText, 2),
            html = candidate(.html, 3)
        let others = [candidate(.image, 4), candidate(.files, 5), candidate(.fileURL, 6), candidate(.color, 7),
                      candidate(.unknown, 8), candidate(.plainText, 9, secret: true), candidate(.url, 10, secret: true),
                      candidate(.plainText, 11, done: true)]
        XCTAssertEqual(TopicPlan.nextBatch(clips: (others + [html, rich, link, text]).shuffled(), skipping: []),
                       [text.id, link.id, rich.id, html.id], "text and links only, newest first")
    }

    func testBatchHolds10AmongTheNewest1000() {
        let clips = (0..<1100).map { candidate(.plainText, $0) }
        XCTAssertEqual(TopicPlan.nextBatch(clips: clips.shuffled(), skipping: []), clips.prefix(10).map(\.id))
        let newestDone = clips.enumerated().map { $0.offset < 1000 ? candidate(.plainText, $0.offset, done: true) : $0.element }
        XCTAssertEqual(TopicPlan.nextBatch(clips: newestDone, skipping: []), [], "past the newest 1,000, never asked")
    }

    /// A clip the model failed on in this pass waits for the next fill.
    func testBatchSkipsThePassFailures() {
        let a = candidate(.plainText, 0), b = candidate(.plainText, 1)
        XCTAssertEqual(TopicPlan.nextBatch(clips: [a, b], skipping: [a.id]), [b.id])
    }

    func testPreviewsAreTruncatedTo300Characters() {
        let long = String(repeating: "a", count: 299) + "bc"
        let prompt = TopicPlan.prompt(previews: [long, "short"])
        XCTAssertTrue(prompt.contains(String(repeating: "a", count: 299) + "b"))
        XCTAssertFalse(prompt.contains("bc"), "character 301 never reaches the model")
        XCTAssertTrue(prompt.contains("short"))
    }

    func testPreviewLeadsWithTheLinkTitle() {
        XCTAssertEqual(TopicPlan.preview(text: "https://example.com/a", title: "Flights to Lisbon"),
                       "Flights to Lisbon\nhttps://example.com/a")
        XCTAssertEqual(TopicPlan.preview(text: "Buy milk", title: nil), "Buy milk")
        XCTAssertEqual(TopicPlan.preview(text: "Buy milk", title: ""), "Buy milk")
        XCTAssertEqual(TopicPlan.preview(text: nil, title: nil), "")
    }

    func testDoneVersusRetry() {
        XCTAssertEqual(TopicPlan.outcome("travel"), .topic(.travel))
        XCTAssertEqual(TopicPlan.outcome("other"), .other)
        XCTAssertEqual(TopicPlan.outcome("links"), .other, "a type board is never a topic")
        XCTAssertTrue(TopicPlan.Outcome.topic(.work).isDone)
        XCTAssertEqual(TopicPlan.Outcome.topic(.work).topicRaw, "work")
        XCTAssertTrue(TopicPlan.Outcome.other.isDone)
        XCTAssertNil(TopicPlan.Outcome.other.topicRaw)
        XCTAssertTrue(TopicPlan.Outcome.unavailable.isDone)
        XCTAssertNil(TopicPlan.Outcome.unavailable.topicRaw)
        XCTAssertFalse(TopicPlan.Outcome.failed.isDone, "a failure is asked again by the next fill")
    }

    func testEveryTopicBoardIsAModelAnswer() {
        XCTAssertEqual(SmartBoard.allCases.filter(\.isTopic).map { TopicPlan.outcome($0.rawValue) },
                       SmartBoard.allCases.filter(\.isTopic).map { .topic($0) })
    }
}

/// The topic fill pass, with a fake model: newest first, 10 at a time, written with the local-only save.
@MainActor
final class TopicQueueTests: XCTestCase {
    private var container: ModelContainer!
    private var saves: [Set<UUID>] = []
    private var defaults: UserDefaults!
    private let suite = "TopicQueueTests"

    override func setUp() async throws {
        container = try ModelContainer(
            for: ClipboardItem.self, Pinboard.self, PinboardEntry.self, ExcludedApp.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        saves = []
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    @discardableResult
    private func insert(_ type: ContentType, _ text: String?, dt: TimeInterval = 0, secret: Bool = false,
                        title: String? = nil) throws -> ClipboardItem {
        let item = ClipboardItem(contentType: type, rawData: Data((text ?? "").utf8), textContent: text,
                                 contentHash: UUID().uuidString)
        item.copiedAt = Date(timeIntervalSince1970: 1_800_000_000 + dt)
        item.isSensitive = secret
        item.linkTitle = title
        container.mainContext.insert(item)
        try container.mainContext.save()
        return item
    }

    /// Every preview the fake model was asked about, in order.
    private final class Model: @unchecked Sendable {
        private let lock = NSLock()
        private var _asked: [String] = []
        var asked: [String] { lock.withLock { _asked } }
        let answer: @Sendable (String, Int) async -> TopicPlan.Outcome

        init(answer: @escaping @Sendable (String, Int) async -> TopicPlan.Outcome) { self.answer = answer }

        func classify(_ preview: String) async -> TopicPlan.Outcome {
            let call = lock.withLock { _asked.append(preview); return _asked.count }
            return await answer(preview, call)
        }
    }

    private func makeQueue(_ model: Model) -> TopicQueue {
        TopicQueue(container: container, isEnabled: { true }, defaults: defaults,
                   classify: { await model.classify($0) }) { [unowned self] ids in
            saves.append(ids)
            try? container.mainContext.save()
        }
    }

    private func finish(_ queue: TopicQueue) async {
        while let task = queue.task { await task.value }
    }

    func testOnlyTextAndLinksReachTheModel() async throws {
        let note = try insert(.plainText, "Quarterly planning meeting at 10", dt: 5)
        let link = try insert(.url, "https://example.com/flights", dt: 4, title: "Flights to Lisbon")
        let image = try insert(.image, nil, dt: 3)
        let files = try insert(.files, "Notes.txt", dt: 2)
        let secret = try insert(.plainText, "hunter2-password", dt: 1, secret: true)
        let model = Model { preview, _ in preview.contains("Lisbon") ? .topic(.travel) : .topic(.work) }
        let queue = makeQueue(model)
        queue.fill()
        await finish(queue)
        XCTAssertEqual(model.asked, ["Quarterly planning meeting at 10", "Flights to Lisbon\nhttps://example.com/flights"])
        XCTAssertEqual(note.topicRaw, "work")
        XCTAssertEqual(link.topicRaw, "travel")
        XCTAssertTrue(note.topicDone && link.topicDone)
        for clip in [image, files, secret] {
            XCTAssertNil(clip.topicRaw)
            XCTAssertFalse(clip.topicDone)
        }
        XCTAssertEqual(saves, [[note.id, link.id]], "one batch, through the local-only save")
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    func testFillRunsInBatchesOf10() async throws {
        for i in 0..<25 { try insert(.plainText, "note \(i)", dt: TimeInterval(i)) }
        let queue = makeQueue(Model { _, _ in .other })
        queue.fill()
        await finish(queue)
        XCTAssertEqual(saves.map(\.count), [10, 10, 5])
    }

    /// A failure leaves the clip undone: never asked again in the same pass, asked again by the next fill.
    func testFailureRetriesOnTheNextFill() async throws {
        let clip = try insert(.plainText, "Invoice 2026-114 due Friday")
        let model = Model { _, call in call == 1 ? .failed : .topic(.finance) }
        let queue = makeQueue(model)
        queue.fill()
        await finish(queue)
        XCTAssertEqual(model.asked.count, 1)
        XCTAssertFalse(clip.topicDone)
        XCTAssertNil(clip.topicRaw)
        XCTAssertEqual(saves, [])
        queue.fill()
        await finish(queue)
        XCTAssertEqual(clip.topicRaw, "finance")
        XCTAssertTrue(clip.topicDone)
    }

    func testOtherIsDoneWithNoTopic() async throws {
        let clip = try insert(.plainText, "asdf qwerty")
        let model = Model { _, _ in .other }
        let queue = makeQueue(model)
        queue.fill()
        await finish(queue)
        XCTAssertTrue(clip.topicDone)
        XCTAssertNil(clip.topicRaw)
        queue.fill()
        await finish(queue)
        XCTAssertEqual(model.asked.count, 1, "never asked again")
    }

    /// Unavailable marks the clip done with no topic and ends the pass; once the model answers again, the version key
    /// resets those clips so they are asked again.
    func testUnavailableIsDoneUntilTheModelIsBack() async throws {
        let a = try insert(.plainText, "Flight AA 100 to Lisbon", dt: 1)
        let b = try insert(.plainText, "Gym at 7", dt: 0)
        let gone = makeQueue(Model { _, _ in .unavailable })
        gone.fill()
        await finish(gone)
        XCTAssertTrue(a.topicDone)
        XCTAssertNil(a.topicRaw)
        XCTAssertFalse(b.topicDone, "the pass ends at the first unavailable answer")
        let back = makeQueue(Model { _, _ in .topic(.travel) })
        back.fill()
        await finish(back)
        XCTAssertEqual(a.topicRaw, "travel", "asked again")
        XCTAssertEqual(b.topicRaw, "travel")
        XCTAssertEqual(defaults.integer(forKey: TopicPlan.versionDefaultsKey), TopicPlan.version)
    }

    /// An answer never lands on a clip edited, or made a secret, while the model ran.
    func testAnswerIsDroppedWhenTheClipChangedMeanwhile() async throws {
        let edited = try insert(.plainText, "Team offsite agenda", dt: 1)
        let secret = try insert(.plainText, "Dinner with Ana", dt: 0)
        let container = container!, editedID = edited.id, secretID = secret.id
        let model = Model { preview, _ in
            await MainActor.run {
                let context = container.mainContext
                if preview.contains("offsite") {
                    _ = context.syncClip(id: editedID)?.saveEdit("Groceries: eggs, milk", in: context)
                } else {
                    context.syncClip(id: secretID)?.isSensitive = true
                    try? context.save()
                }
            }
            return .topic(.work)
        }
        let queue = makeQueue(model)
        queue.fill()
        await finish(queue)
        XCTAssertNil(secret.topicRaw)
        XCTAssertFalse(secret.topicDone)
        XCTAssertEqual(Array(model.asked.prefix(2)), ["Team offsite agenda", "Dinner with Ana"])
        XCTAssertEqual(edited.topicRaw, "work", "the new text is asked about by the next batch")
        XCTAssertEqual(model.asked.count, 3)
    }

    func testNothingRunsWhileTurnedOff() async throws {
        let clip = try insert(.plainText, "Quarterly planning")
        let queue = TopicQueue(container: container, isEnabled: { false }, defaults: defaults,
                               classify: { _ in .topic(.work) }) { _ in }
        queue.fill()
        XCTAssertNil(queue.task)
        XCTAssertFalse(clip.topicDone)
    }
}
