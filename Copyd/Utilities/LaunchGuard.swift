import AppKit

/// Keeps a single Copyd running: two would mean two clipboard monitors, two sync engines and fighting hotkeys.
enum LaunchGuard {
    enum Decision: Equatable {
        case proceed
        /// "Restart Copyd" started this instance: let the old one finish quitting first.
        case waitFor(pid_t)
        /// Copyd is already running: bring it forward and quit this one.
        case quitAndActivate(pid_t)
    }

    /// Passed by "Restart Copyd" as `-CopydRelaunchAfterPID <pid>`; read through the arguments domain.
    static let relaunchAfterPIDKey = "CopydRelaunchAfterPID"

    /// `exitsWithinASecond` waits for the running instance: after a quick quit and relaunch it is only still saving,
    /// and handing over to it would leave nothing running once it is gone.
    static func decide(otherInstancePIDs: [pid_t], relaunchAfterPID: pid_t?,
                       exitsWithinASecond: (pid_t) -> Bool = { _ in false }) -> Decision {
        if let relaunchAfterPID { return otherInstancePIDs.contains(relaunchAfterPID) ? .waitFor(relaunchAfterPID) : .proceed }
        guard let other = otherInstancePIDs.first else { return .proceed }
        return exitsWithinASecond(other) ? .proceed : .quitAndActivate(other)
    }

    /// "Restart Copyd" quits the running instance once the new one launched, or after a short beat with no error:
    /// the new one waits here for this one to quit, so its launch may only report once this one is gone. Never after
    /// a failed launch (`launched == false`), which would leave nothing running.
    static func restartQuits(launched: Bool?, beatPassed: Bool) -> Bool {
        launched ?? beatPassed
    }

    /// Polls until `pid` is gone. kill(pid, 0) rather than NSRunningApplication, whose values only refresh on a main
    /// run loop turn, which this loop blocks. EPERM means the process exists.
    private static func waitForExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while kill(pid, 0) == 0 || errno == EPERM {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    /// Runs first in `CopydApp.init`, before `AppState.shared` exists and before the store, the clipboard monitor,
    /// the hotkeys or the sync engine start.
    @MainActor static func run() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
            .map(\.processIdentifier)
        let relaunch = UserDefaults.standard.integer(forKey: relaunchAfterPIDKey)
        // The waits are synchronous on purpose: no window exists yet, so nothing visibly hangs, and the store must not
        // open while the old instance still has it.
        switch decide(otherInstancePIDs: others, relaunchAfterPID: relaunch > 0 ? pid_t(relaunch) : nil,
                      exitsWithinASecond: { waitForExit($0, timeout: 1) }) {
        case .proceed:
            break
        case .waitFor(let pid):
            _ = waitForExit(pid, timeout: 5)
        case .quitAndActivate(let pid):
            _ = NSRunningApplication(processIdentifier: pid)?.activate()
            exit(0)
        }
    }
}
