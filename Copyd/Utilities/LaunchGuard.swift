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

    static func decide(otherInstancePIDs: [pid_t], relaunchAfterPID: pid_t?) -> Decision {
        if let relaunchAfterPID { return otherInstancePIDs.contains(relaunchAfterPID) ? .waitFor(relaunchAfterPID) : .proceed }
        return otherInstancePIDs.first.map { .quitAndActivate($0) } ?? .proceed
    }

    /// Runs first in `CopydApp.init`, before `AppState.shared` exists and before the store, the clipboard monitor,
    /// the hotkeys or the sync engine start.
    @MainActor static func run() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me && !$0.isTerminated }
            .map(\.processIdentifier)
        let relaunch = UserDefaults.standard.integer(forKey: relaunchAfterPIDKey)
        switch decide(otherInstancePIDs: others, relaunchAfterPID: relaunch > 0 ? pid_t(relaunch) : nil) {
        case .proceed:
            break
        case .waitFor(let pid):
            // Synchronous on purpose: no window exists yet, so nothing visibly hangs, and the store must not open
            // while the old instance still has it. kill(pid, 0) rather than NSRunningApplication, whose values only
            // refresh on a main run loop turn, which this loop blocks. EPERM means the process exists.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, kill(pid, 0) == 0 || errno == EPERM {
                Thread.sleep(forTimeInterval: 0.1)
            }
        case .quitAndActivate(let pid):
            _ = NSRunningApplication(processIdentifier: pid)?.activate()
            exit(0)
        }
    }
}
