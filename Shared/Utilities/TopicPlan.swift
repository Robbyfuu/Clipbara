import Foundation

/// The pure parts of the topic boards: which clips the model is asked about next, what it reads, and what its answer
/// stores. The model itself (FoundationModels) lives in `TopicClassifier`, which only the apps compile.
enum TopicPlan {
    /// "Group by topic with Apple Intelligence". The App Group on iOS, like "Automatic pinboards".
    static let enabledDefaultsKey = "smartTopicsEnabled"
    /// On, under "Automatic pinboards", which turns off every smart board.
    static var isEnabled: Bool {
        SmartKinds.isEnabled && SecretDetector.settings.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// The `version` the clips marked done without a topic were asked under. An unavailable answer stores 0, so once the
    /// model answers again, those clips are asked again. Bump `version` to ask every clip with no topic again.
    static let versionDefaultsKey = "smartTopicsVersion"
    static let version = 1

    /// The fill pass looks at this many of the newest clips, `batchSize` at a time.
    static let window = 1000
    static let batchSize = 10
    /// The model reads at most this many characters of a clip.
    static let previewLimit = 300

    struct Candidate: Sendable {
        let id: UUID
        let contentType: ContentType
        let isSensitive: Bool
        let isDone: Bool
        let copiedAt: Date
    }

    /// The model's answer for one clip. `topic`, `other` and `unavailable` are final: stored with `topicDone`.
    /// `failed` leaves the clip for the next fill.
    enum Outcome: Equatable, Sendable {
        case topic(SmartBoard), other, unavailable, failed

        var isDone: Bool { self != .failed }
        var topicRaw: String? { if case .topic(let board) = self { board.rawValue } else { nil } }
    }

    /// Only text and links reach the model: never a secret, an image, a file or a color.
    static func isEligible(_ type: ContentType, isSensitive: Bool) -> Bool {
        !isSensitive && [.plainText, .richText, .html, .url].contains(type)
    }

    /// The newest text and link clips not asked yet, at most `limit`, among the `window` newest clips. Never an id in
    /// `skipping`: the model failed on it earlier in this pass.
    static func nextBatch(clips: [Candidate], limit: Int = batchSize, window: Int = window,
                          skipping: Set<UUID>) -> [UUID] {
        clips.sorted { $0.copiedAt > $1.copiedAt }.prefix(window)
            .filter { !$0.isDone && !skipping.contains($0.id) && isEligible($0.contentType, isSensitive: $0.isSensitive) }
            .prefix(limit).map(\.id)
    }

    /// What the model reads of a clip: a link's page title first, then the text. `prompt` cuts it.
    static func preview(text: String?, title: String?) -> String {
        [title, text].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: "\n")
    }

    static let instructions = """
        You sort clipboard clips into topics. Answer with the one topic the clip is mostly about:
        work: jobs, meetings, projects, code, business documents and email.
        shopping: products, orders, stores, prices, deliveries.
        travel: trips, flights, hotels, bookings, places and directions.
        finance: money, banking, bills, invoices, payments, taxes.
        study: school, courses, learning, research, articles.
        social: friends, chats, social networks, parties and events.
        personal: home, family, health, errands, notes to self.
        other: none of these fits clearly, or the clip is too short to tell.
        """

    /// The clips, numbered, each cut to `previewLimit` characters.
    static func prompt(previews: [String]) -> String {
        previews.enumerated().map { "Clip \($0.offset + 1): \($0.element.prefix(previewLimit))" }
            .joined(separator: "\n")
    }

    /// The model's answer, by its raw value: a topic board, or `other` for anything else.
    static func outcome(_ topic: String) -> Outcome {
        SmartBoard(rawValue: topic).flatMap { $0.isTopic ? .topic($0) : nil } ?? .other
    }
}
