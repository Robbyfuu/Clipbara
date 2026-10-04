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

    /// Once any clip has history, one never pasted in this app is not suggested here; a new app gets none.
    func testClipsNeverPastedHereWaitWhileAnyHistoryExists() {
        let pastedHere = clip(copiedDaysAgo: 5), elsewhere = clip(), never = clip()
        let events = pastes(pastedHere, in: here) + pastes(elsewhere, in: "com.apple.Terminal", count: 5)
        XCTAssertEqual(rank([never, elsewhere, pastedHere], events), [pastedHere.id])
        XCTAssertEqual(rank([never, elsewhere, pastedHere], events, app: "com.apple.Notes"), [])
    }
}
