# Requeue fix report

## Changes
- Shared/Sync/RemoteApplier.swift:68-79: new `static func uploadableIDs(in:onlyUnconfirmed:) throws -> [UUID]` (same fileURL filters as before, optional `syncSystemFields == nil` filter, no rawData read).
- Shared/Sync/CloudSyncEngine.swift:516-529 (startEngine): with saved state, queues saves for `uploadableIDs(onlyUnconfirmed: true)` and logs "Re-queued N unconfirmed records" at notice level only when N > 0.
- Shared/Sync/CloudSyncEngine.swift:~536-542 (queueEverything): now uses `uploadableIDs(onlyUnconfirmed: false)`; behavior unchanged.
- Tests/RemoteApplierTests.swift (end of file): `testUploadableIDsUnconfirmedOnly`, `testUploadableIDsAllSkipsFileClips`.

## TDD evidence
- RED: tests added before the implementation; the test build failed on the missing symbol (`RemoteApplier.uploadableIDs`): "RemoteApplierTests.swift:326:37 / :332:37: error: failed to produce diagnostic for expression" followed by `** TEST FAILED **`. This is a compile-level red, not an assertion failure.
- GREEN: after implementing, both new tests pass.
- Suite: `Executed 177 tests, with 0 failures (0 unexpected)` / `** TEST SUCCEEDED **` (175 + 2).

## Builds
- Mac (Copyd, Debug, -allowProvisioningUpdates): BUILD SUCCEEDED.
- iOS simulator (CopydiOS, Debug): BUILD SUCCEEDED.
- Mac app: /Users/roberto/Code/Clipbara/.claude/worktrees/icloud-sync/DerivedData/Build/Products/Debug/Copyd.app

## Concerns
- The CopydTests target does not compile CloudSyncEngine.swift, so a first edit of mine with a syntax error there passed the test run and was only caught by the app builds (fixed). The startEngine wiring itself has no automated test (needs a live CKSyncEngine).
- The red run is a compile failure, not an assertion failure.
- Records that fail permanently (e.g. oversized) are re-queued on every launch, since they never get system fields; they are dropped again when the batch is built.
- Untracked `DerivedData-device/` and `.serena/` were not committed.
