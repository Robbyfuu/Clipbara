import XCTest

final class SuggestionPicksTests: XCTestCase {
    private struct Failure: Error {}

    func testValidateDropsOutOfRangeAndDuplicatesAndKeepsThreeInOrder() {
        XCTAssertEqual(SuggestionPicks.validate(indices: [4, 99, -1, 4, 0, 2, 3], count: 5), [4, 0, 2])
    }

    func testEmptyAfterValidationFallsBack() {
        let habit = [UUID(), UUID(), UUID()]
        XCTAssertEqual(SuggestionPicks.validate(indices: [3, -1, 3], count: 3), [])
        XCTAssertNil(SuggestionPicks.reorder([3, -1, 3], of: habit))
        XCTAssertNil(SuggestionPicks.reorder([], of: habit))
    }

    /// The model's picks lead; the habit order fills the rest, so the row keeps its length through the swap.
    func testPicksLeadThenTheHabitFillsTheRow() {
        let habit = (0..<5).map { _ in UUID() }
        XCTAssertEqual(SuggestionPicks.reorder([3, 0], of: habit), [habit[3], habit[0], habit[1]])
        XCTAssertEqual(SuggestionPicks.reorder([1], of: Array(habit.prefix(2))), [habit[1], habit[0]])
    }

    func testPreviewIsOneLineOfAtMostPreviewLimitCharacters() {
        XCTAssertEqual(SuggestionPicks.previewLimit, 80, "the latency budget")
        XCTAssertEqual(SuggestionPicks.preview("  git status\n\n\tgit push  "), "git status git push")
        let long = SuggestionPicks.preview(String(repeating: "a\n", count: 500))
        XCTAssertEqual(long.count, SuggestionPicks.previewLimit)
        XCTAssertFalse(long.contains("\n"))
        XCTAssertEqual(SuggestionPicks.preview(nil), "")
    }

    /// The model gets at most the habit's top clips within the budget, and nothing when there are 3 or fewer.
    func testRerankSendsTheHabitTopEightAndSkipsThreeOrFewer() {
        XCTAssertEqual(SuggestionPicks.rerankCandidateLimit, 8, "the latency budget")
        XCTAssertEqual(SuggestionPicks.rerankInput(Array(0..<15)), Array(0..<SuggestionPicks.rerankCandidateLimit))
        XCTAssertEqual(SuggestionPicks.rerankInput(Array(0..<4)), Array(0..<4))
        XCTAssertEqual(SuggestionPicks.rerankInput(Array(0..<3)), [])
        XCTAssertEqual(SuggestionPicks.rerankInput([Int]()), [])
    }

    func testFirstWithinReturnsAFastAnswer() async {
        let value = await SuggestionPicks.firstWithin(timeout: .seconds(5)) { 42 }
        XCTAssertEqual(value, 42)
    }

    func testFirstWithinGivesUpOnASlowSource() async {
        let start = ContinuousClock.now
        let value = await SuggestionPicks.firstWithin(timeout: .milliseconds(50)) { () async throws -> Int in
            try await Task.sleep(for: .seconds(5))
            return 42
        }
        XCTAssertNil(value)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testFirstWithinTreatsAnErrorAsNoAnswer() async {
        let value = await SuggestionPicks.firstWithin(timeout: .seconds(5)) { () async throws -> Int in throw Failure() }
        XCTAssertNil(value)
    }
}
