import CloudKit
import XCTest

final class SyncBatchPlannerTests: XCTestCase {
    private typealias C = SyncBatchPlanner.Candidate
    private let mb = 1_048_576

    private func save(_ kind: SyncBatchPlanner.Kind, bytes: Int = 1) -> C {
        C(change: .saveRecord(SyncRecordMapper.recordID(for: UUID())), kind: kind, byteCount: bytes)
    }

    private func delete() -> C {
        C(change: .deleteRecord(SyncRecordMapper.recordID(for: UUID())), kind: nil, byteCount: 0)
    }

    func testDeletesFirstThenClipsPinboardsEntries() {
        let input = [save(.entry), save(.pinboard), save(.clip), delete(), save(.clip), delete()]
        let expected = [input[3], input[5], input[2], input[4], input[1], input[0]].map(\.change)
        XCTAssertEqual(SyncBatchPlanner.select(input), expected)
    }

    func testRecordCap() {
        XCTAssertEqual(SyncBatchPlanner.select((0..<150).map { _ in save(.clip) }).count, 100)
    }

    func testByteCap() {
        XCTAssertEqual(SyncBatchPlanner.select((0..<3).map { _ in save(.clip, bytes: 30 * mb) }).count, 1)
    }

    func testOversizedFirstCandidateStillSelected() {
        XCTAssertEqual(SyncBatchPlanner.select([save(.clip, bytes: 60 * mb)]).count, 1)
    }

    func testEmptyInput() {
        XCTAssertTrue(SyncBatchPlanner.select([]).isEmpty)
    }
}
