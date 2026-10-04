import XCTest

/// What a starting Copyd does when it finds another instance, or was started by "Restart Copyd".
final class LaunchGuardTests: XCTestCase {
    func testProceedsWhenAlone() {
        XCTAssertEqual(LaunchGuard.decide(otherInstancePIDs: [], relaunchAfterPID: nil), .proceed)
    }

    func testHandsOverToTheRunningInstance() {
        XCTAssertEqual(LaunchGuard.decide(otherInstancePIDs: [412], relaunchAfterPID: nil), .quitAndActivate(412),
                       "two monitors and two sync engines must never run at once")
    }

    func testRelaunchWaitsForTheOldInstanceToQuit() {
        XCTAssertEqual(LaunchGuard.decide(otherInstancePIDs: [412], relaunchAfterPID: 412), .waitFor(412))
    }

    func testRelaunchProceedsOnceTheOldInstanceIsGone() {
        XCTAssertEqual(LaunchGuard.decide(otherInstancePIDs: [], relaunchAfterPID: 412), .proceed)
    }
}
