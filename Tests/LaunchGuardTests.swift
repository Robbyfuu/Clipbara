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

    func testProceedsWhenTheRunningInstanceWasOnlyQuitting() {
        XCTAssertEqual(LaunchGuard.decide(otherInstancePIDs: [412], relaunchAfterPID: nil, exitsWithinASecond: { $0 == 412 }),
                       .proceed, "a quick quit and relaunch: the old instance was still saving, so nothing would be left")
    }

    func testHandsOverWhenTheRunningInstanceStays() {
        XCTAssertEqual(LaunchGuard.decide(otherInstancePIDs: [412], relaunchAfterPID: nil, exitsWithinASecond: { _ in false }),
                       .quitAndActivate(412))
    }

    // MARK: - "Restart Copyd": when the running instance quits

    func testRestartQuitsOnceTheNewInstanceLaunched() {
        XCTAssertTrue(LaunchGuard.restartQuits(launched: true, beatPassed: false))
    }

    func testRestartQuitsAfterTheBeatWithNoError() {
        XCTAssertFalse(LaunchGuard.restartQuits(launched: nil, beatPassed: false))
        XCTAssertTrue(LaunchGuard.restartQuits(launched: nil, beatPassed: true),
                      "the new instance waits for this one in LaunchGuard, so its success may never come first")
    }

    func testRestartNeverQuitsWhenTheLaunchFailed() {
        XCTAssertFalse(LaunchGuard.restartQuits(launched: false, beatPassed: false))
        XCTAssertFalse(LaunchGuard.restartQuits(launched: false, beatPassed: true), "nothing would be left running")
    }
}
