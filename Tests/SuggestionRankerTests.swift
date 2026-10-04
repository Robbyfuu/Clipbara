import SwiftData
import XCTest

final class SuggestionRankerTests: XCTestCase {
    private typealias Candidate = SuggestionRanker.Candidate
    private typealias Event = SuggestionRanker.Event

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let here = "com.apple.Safari"

    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func clip(copiedDaysAgo days: Double = 0) -> Candidate {
        Candidate(id: UUID(), copiedAt: ago(days: days), isPinned: false)
    }

    private func pastes(_ clip: Candidate, in app: String, count: Int = 1, daysAgo days: Double = 0) -> [Event] {
        Array(repeating: Event(clipID: clip.id, appBundleID: app, at: ago(days: days)), count: count)
    }

    private func rank(_ candidates: [Candidate], _ events: [Event], app: String? = nil) -> [UUID] {
        SuggestionRanker.rank(candidates: candidates, events: events, app: app ?? here, now: now)
    }

    /// A paste here counts 3 + 1, one elsewhere only 1: two here beat one here plus three elsewhere.
    func testPerAppBeatsGlobal() {
        let twiceHere = clip(), mostlyElsewhere = clip()
        let events = pastes(twiceHere, in: here, count: 2)
            + pastes(mostlyElsewhere, in: here) + pastes(mostlyElsewhere, in: "com.apple.Terminal", count: 3)
        XCTAssertEqual(rank([mostlyElsewhere, twiceHere], events), [twiceHere.id, mostlyElsewhere.id])
    }

    /// Two pastes a week old weigh what one today does: just under a week they win, just over they lose.
    func testDecayHalvesWeeklyWeight() {
        let fresh = clip(), older = clip()
        let today = pastes(fresh, in: here)
        XCTAssertEqual(rank([fresh, older], today + pastes(older, in: here, count: 2, daysAgo: 6.9)), [older.id, fresh.id])
        XCTAssertEqual(rank([older, fresh], today + pastes(older, in: here, count: 2, daysAgo: 7.1)), [fresh.id, older.id])
    }

    /// Copies over three years old have no recency left, so equal pastes tie exactly: the newer copy goes first.
    func testTiesByCopiedAt() {
        let older = clip(copiedDaysAgo: 3_000), newer = clip(copiedDaysAgo: 2_000)
        let events = pastes(older, in: here) + pastes(newer, in: here)
        XCTAssertEqual(rank([older, newer], events), [newer.id, older.id])
    }

    /// Nothing pasted yet: the newest copies.
    func testEmptyHistoryFallsBackToRecency() {
        let clips = [clip(copiedDaysAgo: 3), clip(copiedDaysAgo: 0.5), clip(copiedDaysAgo: 10),
                     clip(copiedDaysAgo: 1), clip(copiedDaysAgo: 0.1)]
        XCTAssertEqual(rank(clips, []), [clips[4].id, clips[1].id, clips[3].id])
    }

    /// Events of a clip that is gone are not history: never suggested, and the rest still fall back to recency.
    func testDeletedClipsAreNotSuggested() {
        let clips = [clip(copiedDaysAgo: 2), clip(copiedDaysAgo: 1)]
        let events = [Event(clipID: UUID(), appBundleID: here, at: now)]
        XCTAssertEqual(rank(clips, events), [clips[1].id, clips[0].id])
    }

    func testLimitThree() {
        let clips = (0..<5).map { _ in clip() }
        XCTAssertEqual(rank(clips, clips.flatMap { pastes($0, in: here) }).count, 3)
    }

    /// Once this app has history, a clip never pasted here is not suggested here.
    func testClipsNeverPastedHereWaitWhileThisAppHasHistory() {
        let pastedHere = clip(copiedDaysAgo: 5), elsewhere = clip(), never = clip()
        let events = pastes(pastedHere, in: here) + pastes(elsewhere, in: "com.apple.Terminal", count: 5)
        XCTAssertEqual(rank([never, elsewhere, pastedHere], events), [pastedHere.id])
    }

    /// An app with no pastes yet still gets three: the clips pasted most anywhere, then the newest copies.
    func testNewAppUsesGlobalHabitAndRecency() {
        let habit = clip(copiedDaysAgo: 30), once = clip(copiedDaysAgo: 30), newest = clip(), older = clip(copiedDaysAgo: 2)
        let events = pastes(habit, in: "com.apple.Terminal", count: 3) + pastes(once, in: here)
        XCTAssertEqual(rank([older, newest, once, habit], events, app: "com.apple.Notes"), [habit.id, once.id, newest.id])
    }
}

@MainActor
final class SuggestionCandidateTests: XCTestCase {
    /// Suggestions are text-like picks, and the model must never see a file: pinned or not, a file clip is never
    /// a candidate. It still shows in the usual row.
    func testPinnedFileClipIsNeverACandidate() throws {
        let container = try ModelContainer(for: ClipboardItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        func add(_ type: ContentType, pinned: Bool) -> ClipboardItem {
            let item = ClipboardItem(contentType: type, rawData: Data(), textContent: type.rawValue, contentHash: UUID().uuidString)
            item.isPinned = pinned
            context.insert(item)
            return item
        }
        let text = add(.plainText, pinned: false), pinnedLink = add(.url, pinned: true)
        _ = [add(.files, pinned: true), add(.fileURL, pinned: true), add(.files, pinned: false)]
        try context.save()
        XCTAssertEqual(Set(SuggestionRanker.candidateClips(in: context).map(\.id)), [text.id, pinnedLink.id])
    }

    /// The fetch loads only what ranking and the prompt read; anything else still loads on access, unchanged.
    func testLightFetchStillLoadsTheRestOnAccess() throws {
        let container = try ModelContainer(for: ClipboardItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let item = ClipboardItem(contentType: .plainText, rawData: Data("raw".utf8), textContent: "git status",
                                 sourceAppName: "Terminal", contentHash: "h")
        container.mainContext.insert(item)
        try container.mainContext.save()
        let fetched = try XCTUnwrap(SuggestionRanker.candidateClips(in: ModelContext(container)).first)
        XCTAssertEqual(fetched.id, item.id)
        XCTAssertEqual(fetched.textContent, "git status")
        XCTAssertEqual(fetched.contentType, .plainText)
        XCTAssertEqual(fetched.sourceAppName, "Terminal")
        XCTAssertEqual(fetched.rawData, Data("raw".utf8))
    }
}

final class SuggestedRowTests: XCTestCase {
    private struct Card: Identifiable, Equatable { let id: Int }

    /// Suggestions lead the row in rank order, and each appears only there.
    func testMergeLeadsWithSuggestionsAndDropsThemFromTheRest() {
        let row = SuggestedRow.merge(suggested: [Card(id: 7), Card(id: 2), Card(id: 9)],
                                     rest: (1...9).map(Card.init))
        XCTAssertEqual(row.map(\.id), [7, 2, 9, 1, 3, 4, 5, 6, 8])
    }

    func testNoSuggestionsLeavesTheRowAsIs() {
        XCTAssertEqual(SuggestedRow.merge(suggested: [], rest: (1...3).map(Card.init)).map(\.id), [1, 2, 3])
    }
}
