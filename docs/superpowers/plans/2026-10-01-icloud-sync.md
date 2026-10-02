# Copyd iCloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync clipboard history and pinboards between the user's Macs through CloudKit, end-to-end encrypted, in the `ClipbaraMAS` target rebranded to bundle `com.robbyfuu.copyd`.

**Architecture:** A single `ModelContext.willSave` observer (`LocalChangeTracker`) turns local SwiftData changes into `CKSyncEngine` pending changes. `CloudSyncEngine` (the `CKSyncEngineDelegate`) uploads records built by a pure mapper and applies fetched records through `RemoteApplier`. Pure units (mapper, crypto, duplicate rule, batch planner) carry the logic and are unit-tested. The engine is thin glue, verified on two real Macs.

**Tech Stack:** Swift 6 (strict concurrency complete), SwiftData, CloudKit `CKSyncEngine` (macOS 14), CryptoKit AES-GCM, XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-01-icloud-sync-design.md`. Read it before any task.

## Global Constraints

- macOS deployment target 14.0. Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. No `#Index` or `#Unique`.
- No new SPM dependencies. CloudKit and CryptoKit are system frameworks.
- Every SwiftData mutation is followed by a save. Sync code uses `do { try context.save() } catch { logger.error(...) }`; UI code keeps the existing `try? modelContext.save()`.
- The DMG target `Clipbara` must keep building and behave as upstream. Sync wiring lives only behind `#if CLOUDSYNC`.
- Fixed values: container `iCloud.com.robbyfuu.copyd`; zone `Clipboard`; record types `Clip`, `Pinboard`, `PinboardEntry`; inline limit 262_144 bytes (256 KB, inclusive); max clip 20_971_520 bytes (20 MB, inclusive); duplicate window 60 s (inclusive); fetch throttle 30 s; defaults key `iCloudSyncEnabled`; state file `SyncState.data`.
- Code, identifiers and comments in English. Commit format `[type] what and why`, with **no** `Co-Authored-By` line.
- Logger subsystem `com.robbyfuu.copyd`, category `Sync`.
- Regenerate the project after editing `project.yml`: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate`.
- Test command (prefix `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`): `xcodebuild test -project Clipbara.xcodeproj -scheme ClipbaraTests -destination 'platform=macOS' -only-testing:ClipbaraTests/<TestClass>`. Baseline: 52 tests pass.

## Review Focus

1. **Re-enabling sync, or switching iCloud accounts, with stale `syncSystemFields`:** the server answers `unknownItem`, and the spec's rule then deletes the clip locally. Disabling must clear every `syncSystemFields`. Pinned by `RemoteApplierTests.testClearSystemFieldsResetsEveryModel` (Task 8), called from `CloudSyncEngine.stop(clearState:)` (Task 9).
2. **First enable with hundreds of large images:** building every record at once writes gigabytes of temporary assets. Pinned by `SyncBatchPlannerTests` byte-cap tests (Task 6).
3. **A remote clip deletion while the clip sits in a local pinboard:** `ClipboardItem` has no cascade to `PinboardEntry`, so the entry would be orphaned with a nil clip. Pinned by `RemoteApplierTests.testDeletingClipRemovesItsEntries` (Task 8).
4. **Applying remote changes echoing back as uploads:** this is an infinite sync loop. Pinned by `LocalChangeTrackerTests.testSuppressedSaveQueuesNothing` (Task 7).
5. **A pinboard entry arriving before its clip:** pinned by `RemoteApplierTests.testEntryWithMissingClipIsReturnedAsOrphan` (Task 8).

---

## File Map

| File | Status | Responsibility |
|---|---|---|
| `project.yml` | Modify | `ClipbaraMAS` identity, signing, entitlements, `CLOUDSYNC`; test target sources |
| `Clipbara/Models/ClipboardItem.swift`, `Pinboard.swift`, `PinboardEntry.swift` | Modify | Add `syncSystemFields: Data?` |
| `Clipbara/Utilities/Thumbnail.swift` | Create | Thumbnail PNG generation, moved out of `ClipboardMonitor` |
| `Clipbara/Services/ClipboardMonitor.swift` | Modify | Call `Thumbnail.png(from:)` |
| `Clipbara/Sync/AssetCrypto.swift` | Create | AES-GCM seal and open |
| `Clipbara/Sync/SyncRecordMapper.swift` | Create | Snapshots, eligibility, `CKRecord` encode and decode |
| `Clipbara/Sync/DuplicateRule.swift` | Create | Universal Clipboard duplicate merge decision |
| `Clipbara/Sync/SyncBatchPlanner.swift` | Create | Upload batch ordering and caps |
| `Clipbara/Sync/ModelSnapshots.swift` | Create | Model ↔ snapshot conversion; lookup by UUID |
| `Clipbara/Sync/LocalChangeTracker.swift` | Create | `willSave` observer → pending changes |
| `Clipbara/Sync/RemoteApplier.swift` | Create | Apply fetched snapshots to SwiftData |
| `Clipbara/Sync/CloudSyncEngine.swift` | Create | `CKSyncEngineDelegate` glue, state, errors, status |
| `Clipbara/AppState.swift` | Modify | Create and start the engine (`#if CLOUDSYNC`); fetch on panel open |
| `Clipbara/Views/Settings/GeneralSettingsTab.swift` | Modify | iCloud Sync section (`#if CLOUDSYNC`) |
| `Tests/*Tests.swift` | Create | One test file per unit |
| `docs/testing/icloud-sync.md` | Create | Two-Mac verification record |

---

### Task 1: Spike on the two local risks

Throwaway code. Do not commit it; only the results are kept.

**Files:**
- Modify: `docs/superpowers/plans/2026-10-01-icloud-sync.md` (append the results under this task)

**Interfaces:**
- Produces: a decision for Task 7 (tracker approach) and Task 9 (delegate isolation).

- [ ] **Step 1: Risk 1.** In a scratch test in the test target, with the models temporarily added to its sources, create an in-memory `ModelContainer` for the four models. Observe `ModelContext.willSave` on `container.mainContext`, delete one `ClipboardItem`, and save. Record whether the deleted model shows up in `context.deletedModelsArray` inside the observer, and whether its `id` is readable.
- [ ] **Step 2: Risk 2.** In a scratch file, declare `@MainActor final class SpikeDelegate: CKSyncEngineDelegate` with both required methods as empty stubs. Build the `ClipbaraMAS` target. Record whether it compiles under strict concurrency without warnings.
- [ ] **Step 3: Revert the scratch code** (`git checkout -- . && git clean -fd Tests Clipbara`, after checking that `git status` shows only spike files).
- [ ] **Step 4: Append a "Spike results" block** under this task: risk, result, chosen approach. If risk 1 fails, Task 7 uses the spec's fallback, which is explicit `tracker.recordDeletion(id:)` calls at `ClipboardCardView.swift:338-341`, `NavigationBarView.swift:306,392`, `PinboardGridView.swift:145` and `ClipboardMonitor.cleanupOldItems`. If risk 2 fails, Task 9 uses an `actor` delegate that hops to `@MainActor` to touch SwiftData.
- [ ] **Step 5: Commit** with `git commit -m "[docs] Record sync spike results to fix tracker and delegate approach"`.

Risks 3 (push delivery) and 4 (`network.client`) need the signed app and a container, so they are checked in Task 11.

**Spike results**

- **Risk 1 (`willSave` and deleted models): PASS.** `ModelContext.willSave` fires on the macOS 14 SDK for `container.mainContext` (in-memory container with all four models). Inside the observer, for one `ClipboardItem` with id `BAFAD576-...`:
  - insert: `ins=1 chg=0 del=0`, `insertedModelsArray` holds the item and `(model as? ClipboardItem)?.id` returns the right UUID.
  - property change (`userTitle`): `ins=0 chg=1 del=0`, `changedModelsArray` holds the item, id readable.
  - delete: `ins=0 chg=0 del=1`, `deletedModelsArray` holds the item and its `id` is readable and equals the original UUID.
  - **Approach for Task 7:** observe `willSave` and read all three arrays; no explicit `recordDeletion(id:)` call sites are needed. Verified on an in-memory store with single-object deletes on mainContext. As of d628641 the app has no batch deletes (`delete(model:where:)`) and no secondary ModelContext; Task 7 re-checks this if either is introduced.
- **Risk 2 (`@MainActor` `CKSyncEngineDelegate`): PASS.** `@MainActor final class SpikeDelegate: CKSyncEngineDelegate` with `handleEvent(_:syncEngine:) async` and `nextRecordZoneChangeBatch(_:syncEngine:) async -> CKSyncEngine.RecordZoneChangeBatch?` as empty stubs builds in `ClipbaraMAS` (`CODE_SIGNING_ALLOWED=NO`, strict concurrency `complete`): `** BUILD SUCCEEDED **`, with zero errors or warnings from the scratch file. The only warning in the log is the existing `PanelController.swift:147` weak-capture one.
  - **Approach for Task 9:** the delegate is a `@MainActor` class; no actor-with-hop is needed.

---

### Task 2: Copyd identity, signing and entitlements

**Files:**
- Modify: `project.yml`

**Interfaces:**
- Produces: the compilation condition `CLOUDSYNC` (only on `ClipbaraMAS`), bundle `com.robbyfuu.copyd`, and container `iCloud.com.robbyfuu.copyd`.

- [ ] **Step 1: Edit the `ClipbaraMAS` target in `project.yml`:**
  - `PRODUCT_BUNDLE_IDENTIFIER: com.robbyfuu.copyd`
  - Add to `base`: `DEVELOPMENT_TEAM: TQC76W2BKK` and `CODE_SIGN_STYLE: Automatic`
  - Delete the `configs: Release:` manual-signing block
  - `SWIFT_ACTIVE_COMPILATION_CONDITIONS: "APPSTORE CLOUDSYNC $(inherited)"`
  - Add to the entitlement properties: `com.apple.developer.icloud-container-identifiers: [iCloud.com.robbyfuu.copyd]`, `com.apple.developer.icloud-services: [CloudKit]`, `com.apple.developer.aps-environment: development`
- [ ] **Step 2: Regenerate the project and build the DMG target.** `xcodebuild -project Clipbara.xcodeproj -scheme Clipbara -configuration Debug build` must report `BUILD SUCCEEDED`.
- [ ] **Step 3: GATE. This step registers the App ID and creates the iCloud container in the Apple Developer account, which is permanent.** The orchestrator confirms with the user before running it. Then run `xcodebuild -project Clipbara.xcodeproj -scheme ClipbaraMAS -configuration Debug -allowProvisioningUpdates build`. Expected: `BUILD SUCCEEDED`.
- [ ] **Step 4: Verify the entitlements.** Run `codesign -d --entitlements - <DerivedData>/Build/Products/Debug/Clipbara.app` on the MAS product. The output must list `iCloud.com.robbyfuu.copyd`, `CloudKit` and `aps-environment`.
- [ ] **Step 5: Run the full test suite.** Expected: 52 tests, 0 failures.
- [ ] **Step 6: Commit** with `git commit -m "[build] Retarget the App Store build to Copyd with iCloud entitlements for sync"`.

---

### Task 3: Sync attribute on the models and the `Thumbnail` utility

**Files:**
- Modify: `Clipbara/Models/ClipboardItem.swift`, `Clipbara/Models/Pinboard.swift`, `Clipbara/Models/PinboardEntry.swift`
- Create: `Clipbara/Utilities/Thumbnail.swift`
- Modify: `Clipbara/Services/ClipboardMonitor.swift:151-169` (delete `generateThumbnail`, call the utility)
- Modify: `project.yml` (add `Clipbara/Utilities/Thumbnail.swift` to `ClipbaraTests` sources)
- Test: `Tests/ThumbnailTests.swift`

**Interfaces:**
- Produces: `var syncSystemFields: Data?` on the three models, and `enum Thumbnail { static func png(from data: Data, maxSize: CGFloat = 320) -> Data? }`.

- [ ] **Step 1: Write the failing tests** in `ThumbnailTests`:
  - `testLandscapeImageFitsMaxSize`: 1000×500 PNG input; the output decodes with `NSImage(data:)` to size 320×160 points.
  - `testSmallImageIsNotUpscaled`: 100×80 input stays 100×80.
  - `testInvalidDataReturnsNil`: `Data("x".utf8)` returns nil.
- [ ] **Step 2: Run them.** Expected: they fail to compile (`Thumbnail` is undefined).
- [ ] **Step 3: Implement `Thumbnail.png(from:maxSize:)`** by moving the body of `ClipboardMonitor.generateThumbnail` unchanged. The spec (§8) says to make the method `static` instead; it moves to `Utilities` here so the unhosted test target can compile it without `ClipboardMonitor`. Replace the call site with `Thumbnail.png(from: content.rawData)`. Add `var syncSystemFields: Data?` to the three models, with no init change.
- [ ] **Step 4: Run the tests.** Expected: `ThumbnailTests` passes, and the full suite reports 55 tests.
- [ ] **Step 5: Migration check.** The store is at `~/Library/Containers/com.minsang.PasteClip/Data/Library/Application Support/com.minsang.PasteClip/PasteClip.store`.
  1. Before launching, run `sqlite3 "<store>" "select count(*) from ZCLIPBOARDITEM"`.
  2. Build and launch the DMG Debug app (CLAUDE.md commands), then quit it.
  3. Run the same query. The count must be unchanged, and `pragma table_info(ZCLIPBOARDITEM)` must list `ZSYNCSYSTEMFIELDS`.
  4. If no store exists, say so in the task report.
- [ ] **Step 6: Commit** with `git commit -m "[feat] Add sync system fields to synced models and extract thumbnail helper for reuse"`.

---

### Task 4: `AssetCrypto`

**Files:**
- Create: `Clipbara/Sync/AssetCrypto.swift`
- Modify: `project.yml` (add the file to `ClipbaraTests` sources)
- Test: `Tests/AssetCryptoTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum AssetCrypto {
      static func makeKey() -> Data                                 // 32 random bytes
      static func seal(_ plaintext: Data, key: Data) throws -> Data // AES.GCM combined representation
      static func open(_ sealed: Data, key: Data) throws -> Data
  }
  ```

- [ ] **Step 1: Write the failing tests:**
  - `testMakeKeyIs32Bytes`
  - `testRoundTrip`: 1 MB of random data seals and opens to equal bytes.
  - `testSealedDiffersFromPlaintext`
  - `testOpenFailsWithWrongKey`: `XCTAssertThrowsError`.
  - `testOpenFailsWhenTampered`: flip one byte in the middle, then `XCTAssertThrowsError`.
- [ ] **Step 2: Run them.** Expected: compile failure.
- [ ] **Step 3: Implement** with CryptoKit `AES.GCM.seal(_:using:)` and `.combined`.
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "[feat] Add AssetCrypto so large clip payloads stay end-to-end encrypted"`.

---

### Task 5: `SyncRecordMapper` and snapshots

**Files:**
- Create: `Clipbara/Sync/SyncRecordMapper.swift`
- Modify: `project.yml` (test sources)
- Test: `Tests/SyncRecordMapperTests.swift`

**Interfaces:**
- Consumes: `AssetCrypto` (Task 4).
- Produces:
  ```swift
  struct ClipSnapshot: Equatable, Sendable {
      var id: UUID; var contentType: String; var rawData: Data; var textContent: String?
      var userTitle: String?; var sourceAppName: String?; var sourceAppBundleId: String?
      var contentHash: String; var copiedAt: Date; var isPinned: Bool
  }
  struct PinboardSnapshot: Equatable, Sendable { var id: UUID; var name: String; var displayOrder: Int; var createdAt: Date }
  struct EntrySnapshot: Equatable, Sendable { var id: UUID; var clipID: UUID; var pinboardID: UUID; var displayOrder: Int; var addedAt: Date }

  enum SyncRecordMapper {
      static let zoneID: CKRecordZone.ID              // zoneName "Clipboard"
      static let clipType = "Clip", pinboardType = "Pinboard", entryType = "PinboardEntry"
      static let inlineLimit = 262_144
      static let maxClipBytes = 20_971_520
      enum DecodeError: Error { case missingField(String) }
      static func recordID(for id: UUID) -> CKRecord.ID
      static func isEligible(contentType: String, byteCount: Int) -> Bool   // false for "fileURL" or > maxClipBytes
      static func populate(_ record: CKRecord, from clip: ClipSnapshot, assetDirectory: URL) throws
      static func populate(_ record: CKRecord, from board: PinboardSnapshot)
      static func populate(_ record: CKRecord, from entry: EntrySnapshot)
      static func clip(from record: CKRecord) throws -> ClipSnapshot
      static func pinboard(from record: CKRecord) throws -> PinboardSnapshot
      static func entry(from record: CKRecord) throws -> EntrySnapshot
      static func assetURL(for id: UUID, in directory: URL) -> URL      // <dir>/<uuid>.bin
  }
  ```

The field names and plain/encrypted placement are exactly the spec §7 tables. A clip over `inlineLimit` writes `AssetCrypto.seal(rawData)` to `assetURL` and sets `payload = CKAsset(fileURL:)` and the encrypted `assetKey`. Entry references use `action: .deleteSelf`.

- [ ] **Step 1: Write the failing tests** (`assetDirectory` is a fresh temp dir per test):
  - `testClipRoundTripForEachSyncedType`: covers `plainText`, `richText`, `html`, `image`, `url`, `color`, and `unknown`; nil optionals round-trip as nil.
  - `testInlineAtExactlyLimit`: `rawData.count == 262_144` sets `encryptedValues["rawData"]` and no `payload`.
  - `testAssetAboveLimit`: 262_145 bytes sets `payload` and `assetKey`, leaves `encryptedValues["rawData"]` nil, and round-trips to equal `rawData`.
  - `testAssetFileIsNotPlaintext`: the bytes at `assetURL` do not equal `rawData`.
  - `testEligibility`: `fileURL` is false; 20_971_520 bytes is true; 20_971_521 bytes is false.
  - `testOnlyAllowedPlainKeys`: `record.allKeys()` is a subset of `["payload"]` for a clip, empty for a pinboard, and exactly `["clip", "pinboard"]` for an entry.
  - `testEntryReferencesDeleteSelf`
  - `testPinboardRoundTrip`, `testEntryRoundTrip`
  - `testDecodeMissingFieldThrows`: an empty `Clip` record throws `DecodeError.missingField`.
- [ ] **Step 2: Run them.** Expected: compile failure.
- [ ] **Step 3: Implement.** Store `isPinned` and `displayOrder` as `Int64`.
- [ ] **Step 4: Run them.** Expected: PASS. If `encryptedValues` turns out to be unusable without a container in an unhosted test, stop and report it; do not work around it.
- [ ] **Step 5: Commit** with `git commit -m "[feat] Add SyncRecordMapper to encode clips as encrypted CloudKit records"`.

---

### Task 6: `DuplicateRule` and `SyncBatchPlanner`

**Files:**
- Create: `Clipbara/Sync/DuplicateRule.swift`, `Clipbara/Sync/SyncBatchPlanner.swift`
- Modify: `project.yml` (test sources)
- Test: `Tests/DuplicateRuleTests.swift`, `Tests/SyncBatchPlannerTests.swift`

**Interfaces:**
- Consumes: `ClipSnapshot` (Task 5).
- Produces:
  ```swift
  enum DuplicateRule {
      static let window: TimeInterval = 60
      struct Merge: Equatable { let survivorID: UUID; let loserID: UUID; let isPinned: Bool; let userTitle: String? }
      static func merge(_ a: ClipSnapshot, _ b: ClipSnapshot) -> Merge?   // nil when not duplicates
  }
  enum SyncBatchPlanner {
      enum Kind: Int, Comparable { case clip, pinboard, entry }
      struct Candidate { let change: CKSyncEngine.PendingRecordZoneChange; let kind: Kind?; let byteCount: Int } // kind nil for deletes
      static func select(_ candidates: [Candidate], maxRecords: Int = 100, maxBytes: Int = 52_428_800) -> [CKSyncEngine.PendingRecordZoneChange]
  }
  ```

The rules come from spec §10. Duplicates have equal `contentHash`, different `id`, and `abs(copiedAt Δ) <= 60`. The survivor has the smaller `id.uuidString`. `isPinned` is the OR of both. `userTitle` is the survivor's, or the loser's when the survivor's is nil.

`select` puts deletes first, then saves ordered clip → pinboard → entry (stable within a kind). It stops before exceeding `maxRecords` or the cumulative `maxBytes`, but always includes the first candidate.

- [ ] **Step 1: Write the failing tests.**
  - `DuplicateRuleTests`:
    - `testMergesAt59Seconds`, `testMergesAtExactly60Seconds`, `testDoesNotMergeAt61Seconds`
    - `testDifferentHashNeverMerges`, `testSameIDNeverMerges`
    - `testSurvivorIndependentOfOrder`: `merge(a, b) == merge(b, a)`
    - `testPinIsOR`, `testSurvivorTitleWins`, `testLoserTitleFillsNilSurvivorTitle`
  - `SyncBatchPlannerTests`:
    - `testDeletesFirstThenClipsPinboardsEntries`
    - `testRecordCap`: 150 candidates select 100.
    - `testByteCap`: three 30 MB clips select one.
    - `testOversizedFirstCandidateStillSelected`: a single 60 MB clip is selected.
    - `testEmptyInput`
- [ ] **Step 2: Run them.** Expected: compile failure.
- [ ] **Step 3: Implement both.**
- [ ] **Step 4: Run them.** Expected: PASS.
- [ ] **Step 5: Commit** with `git commit -m "[feat] Add duplicate merge rule and upload batch planner for sync"`.

---

### Task 7: `ModelSnapshots` and `LocalChangeTracker`

**Files:**
- Create: `Clipbara/Sync/ModelSnapshots.swift`, `Clipbara/Sync/LocalChangeTracker.swift`
- Modify: `project.yml` (add `Clipbara/Models` and both files to `ClipbaraTests` sources)
- Test: `Tests/LocalChangeTrackerTests.swift`

**Interfaces:**
- Consumes: the snapshots, `SyncRecordMapper.isEligible` and `recordID(for:)` (Task 5).
- Produces:
  ```swift
  // ModelSnapshots.swift
  extension ClipboardItem { var snapshot: ClipSnapshot { get }; func update(from: ClipSnapshot); var isSyncEligible: Bool { get } }
  extension Pinboard { var snapshot: PinboardSnapshot { get }; func update(from: PinboardSnapshot) }
  extension PinboardEntry { var snapshot: EntrySnapshot? { get } }  // nil when clip or pinboard is nil
  extension ModelContext {
      func syncClip(id: UUID) -> ClipboardItem?
      func syncPinboard(id: UUID) -> Pinboard?
      func syncEntry(id: UUID) -> PinboardEntry?
  }

  // LocalChangeTracker.swift
  @MainActor final class LocalChangeTracker {
      init(context: ModelContext, onChanges: @escaping @MainActor ([CKSyncEngine.PendingRecordZoneChange]) -> Void)
      func suppressing(_ ids: Set<UUID>, _ save: () throws -> Void) rethrows  // changes to ids during save are not reported
  }
  ```

The tracker observes `ModelContext.willSave` for `context`. It maps inserted and changed models to `.saveRecord`, and deleted ones to `.deleteRecord`. It reports only synced types, and only eligible clips. An entry is reported only when its clip is eligible and present. Ineligible clips produce no deletes either. Use the approach chosen in Task 1.

- [ ] **Step 1: Write the failing tests.** Every test uses a `@MainActor` in-memory container and asserts on the collected changes after `try context.save()`.
  - `testInsertClipQueuesSave`, `testRenameClipQueuesSave`, `testDeleteClipQueuesDelete`
  - `testInsertPinboardQueuesSave`, `testInsertEntryQueuesSave`
  - `testFileURLClipQueuesNothing`, `testOversizedClipQueuesNothing`, `testEntryForFileURLClipQueuesNothing`
  - `testExcludedAppQueuesNothing`
  - `testSuppressedSaveQueuesNothing`
  - `testSuppressionCoversOnlyListedIDs`: change two clips, suppress one; only the other is reported.
- [ ] **Step 2: Run them.** Expected: compile failure.
- [ ] **Step 3: Implement both files.**
- [ ] **Step 4: Run them.** Expected: PASS, and the full suite passes.
- [ ] **Step 5: Commit** with `git commit -m "[feat] Add LocalChangeTracker so every saved change queues one sync change"`.

---

### Task 8: `RemoteApplier`

**Files:**
- Create: `Clipbara/Sync/RemoteApplier.swift`
- Modify: `project.yml` (test sources)
- Test: `Tests/RemoteApplierTests.swift`

**Interfaces:**
- Consumes: `ModelSnapshots` (Task 7), `DuplicateRule` (Task 6), `Thumbnail` (Task 3).
- Produces:
  ```swift
  @MainActor struct RemoteApplier {
      let context: ModelContext
      let hasPendingSave: (UUID) -> Bool
      struct Outcome: Equatable {
          var saves: Set<UUID> = []      // merge survivors and moved entries to upload
          var deletes: Set<UUID> = []    // merge losers and their dropped entries to delete remotely
          var orphans: [EntrySnapshot] = []
          var touched: Set<UUID> = []    // every id inserted, updated or deleted; pass to tracker.suppressing
      }
      func apply(clips: [ClipSnapshot], pinboards: [PinboardSnapshot], entries: [EntrySnapshot],
                 deletions: [UUID], systemFields: [UUID: Data]) -> Outcome   // does not save
      static func clearSystemFields(in context: ModelContext)               // does not save
  }
  ```

The order is clips, then pinboards, then entries, then deletions. Upsert by id; a new `ClipboardItem` gets its `id` set from the snapshot.

- With `hasPendingSave(id)`, only `syncSystemFields` changes.
- An image clip that is inserted, or whose `rawData` changed, gets `thumbnailData = Thumbnail.png(from:)`.
- After each incoming clip, run `DuplicateRule.merge` against local clips with the same `contentHash`, and apply the merge as spec §10 describes.
- Deleting a clip also deletes the `PinboardEntry` rows that point at it.

- [ ] **Step 1: Write the failing tests.**
  - Basic upserts:
    - `testInsertsNewClipWithAllFieldsAndSystemFields`
    - `testUpdatesClipWithoutPendingSave`
    - `testPendingSaveKeepsLocalFieldsButStoresSystemFields`
    - `testUpsertsPinboard`
    - `testLinksEntryWhenClipAndPinboardExist`
    - `testEntryWithMissingClipIsReturnedAsOrphan`: not inserted.
  - Deletions:
    - `testDeletingClipRemovesItsEntries`
    - `testDeletingPinboardCascadesEntries`
  - Image thumbnails:
    - `testIncomingImageGetsThumbnail`
  - Duplicate merges:
    - `testUniversalClipboardDuplicateMerges`: one clip remains, with the smaller uuid and the OR'ed pin. The outcome lists the survivor in `saves` and the loser in `deletes`.
    - `testMergeMovesLoserEntryToSurvivor`: the moved entry is in `saves`.
    - `testMergeDropsLoserEntryWhenSurvivorAlreadyPinned`: the dropped entry is in `deletes`.
    - `testNoMergeAt61Seconds`
  - Bookkeeping:
    - `testTouchedCoversEveryChangedID`
    - `testClearSystemFieldsResetsEveryModel`
- [ ] **Step 2: Run them.** Expected: compile failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them.** Expected: PASS, and the full suite passes.
- [ ] **Step 5: Commit** with `git commit -m "[feat] Add RemoteApplier to merge fetched records into local history"`.

---

### Task 9: `CloudSyncEngine`

**Files:**
- Create: `Clipbara/Sync/CloudSyncEngine.swift` (not in the test target)

**Interfaces:**
- Consumes: everything from Tasks 4 to 8.
- Produces:
  ```swift
  @MainActor @Observable final class CloudSyncEngine: CKSyncEngineDelegate {
      enum Status: Equatable { case off, syncing, upToDate(Date), accountUnavailable, quotaExceeded, accountChanged, error(String) }
      static let enabledDefaultsKey = "iCloudSyncEnabled"
      static let containerID = "iCloud.com.robbyfuu.copyd"
      private(set) var status: Status
      init(container: ModelContainer, onRemoteChanges: @escaping @MainActor () -> Void)
      func start()                      // no-op when already running
      func stop(clearState: Bool)
      func fetchIfStale()               // fetchChanges() at most once per 30 s
  }
  ```

Behavior, from spec §9 and §11:

1. **`start()`:**
   - Clear the temporary asset directory `FileManager.default.temporaryDirectory/CopydSyncAssets`.
   - Load `SyncState.data` from the directory of `StoreManager.resolveStoreURL()`.
   - Create the `CKSyncEngine` on `CKContainer(identifier:).privateCloudDatabase`.
   - Create the `LocalChangeTracker`, whose `onChanges` adds the changes to `state`.
   - Call `NSApplication.shared.registerForRemoteNotifications()`.
   - With no saved state: add `.saveZone(CKRecordZone(zoneID: SyncRecordMapper.zoneID))` plus `.saveRecord` for every eligible clip, every pinboard, and every entry with a snapshot.
2. **`stop(clearState: true)`:** delete `SyncState.data`, call `RemoteApplier.clearSystemFields` and save inside `tracker.suppressing` of all ids, and set `status = .off`.
3. **`.stateUpdate`:** write the JSON-encoded serialization to `SyncState.data`.
4. **`nextRecordZoneChangeBatch`:**
   - Build `SyncBatchPlanner.Candidate`s from the in-scope pending changes. A save whose model is missing or ineligible is removed from the pending changes.
   - Take `select(...)`. Build records from the unarchived `syncSystemFields`, or from a new `CKRecord`, then `populate`.
   - Return `RecordZoneChangeBatch(recordsToSave:recordIDsToDelete:atomicByZone: false)`.
5. **`.sentRecordZoneChanges`:**
   - For saved records: archive the system fields (`encodeSystemFields(with:)`, secure coding) into the model, inside `suppressing`, then save.
   - Delete each record's temporary asset file.
   - Handle failures per the §11 table. `quotaExceeded` sets `status`. `failedRecordDeletes` with `unknownItem` are ignored.
6. **`.fetchedRecordZoneChanges`:**
   - Decode modifications with the mapper. Skip and log any decode failure.
   - Remove pending saves for deleted ids.
   - Call `RemoteApplier.apply`. Hold `orphans`. Call `tracker.suppressing(outcome.touched)` and save.
   - Add `outcome.saves` and `outcome.deletes` as pending changes, then call `onRemoteChanges()`.
7. **`.didFetchChanges`:** re-apply the held orphans once and drop (with a log line) any that are still orphaned. Set `status = .upToDate(Date())`.
8. **`.fetchedDatabaseChanges`:** handle deletion of our zone. For `.encryptedDataReset`: clear the system fields, `.saveZone`, and queue every record. For `.deleted` or `.purged`: call `stop(clearState: true)` and set the defaults key to false.
9. **`.accountChange`:**
   - `.signIn`: set the status.
   - `.signOut` or `.switchAccounts`: call `stop(clearState: true)`, set the defaults key to false, and set `status = .accountChanged`.

- [ ] **Step 1: Write the type and delegate conformance** using the approach Task 1 chose. Build `ClipbaraMAS` with `-allowProvisioningUpdates`. Expected: `BUILD SUCCEEDED`, with no concurrency warnings from `Sync/`.
- [ ] **Step 2: Implement items 1 to 9.**
- [ ] **Step 3: Build both targets and run the full suite.** Expected: both builds succeed, and every test passes.
- [ ] **Step 4: Commit** with `git commit -m "[feat] Add CloudSyncEngine to drive CKSyncEngine uploads, fetches and errors"`.

---

### Task 10: Wiring and Settings

**Files:**
- Modify: `Clipbara/AppState.swift` (`start(modelContext:modelContainer:)` at lines 38-63, `togglePanel()` at lines 65-76)
- Modify: `Clipbara/Views/Settings/GeneralSettingsTab.swift` (new section after "Pasting")

**Interfaces:**
- Consumes: `CloudSyncEngine` (Task 9).
- Produces: `#if CLOUDSYNC private(set) var cloudSync: CloudSyncEngine?` on `AppState`.

- [ ] **Step 1: `AppState.start`.** Under `#if CLOUDSYNC`, create `CloudSyncEngine(container:onRemoteChanges: { clipboardMonitor.refreshLatestItems() })`, and call `start()` when `UserDefaults.standard.bool(forKey: CloudSyncEngine.enabledDefaultsKey)`. In `togglePanel()`, call `cloudSync?.fetchIfStale()` when opening.
- [ ] **Step 2: Settings.** Under `#if CLOUDSYNC`, add `Section("iCloud Sync")`:
  - A `Toggle("Sync with iCloud")` bound to `@AppStorage(CloudSyncEngine.enabledDefaultsKey)`. `onChange` calls `start()`, or `stop(clearState: true)`.
  - A secondary-style status line with these strings: "Up to date · <relative time>", "Syncing…", "iCloud account unavailable", "iCloud storage full", "iCloud account changed. Sync is off.", "Sync error: <message>", and "Off". Strings are English only; `ko` and `zh-Hans` fall back to English.
- [ ] **Step 3: Build both targets.** The DMG target's Settings must show no iCloud section.
- [ ] **Step 4: Launch the MAS Debug app with the paywall bypass:**
  1. Run `defaults write com.robbyfuu.copyd ClipbaraDebugOriginalAppVersion 1.0`.
  2. Launch the app, enable sync, and confirm the status reaches "Up to date".
  3. In CloudKit Console (Development, container `iCloud.com.robbyfuu.copyd`), confirm the `Clipboard` zone and `Clip` records exist.
- [ ] **Step 5: Commit** with `git commit -m "[feat] Wire iCloud sync into app startup, panel open and Settings"`.

---

### Task 11: Two-Mac verification

The user runs this with the orchestrator, on two Macs signed in to the same Apple ID. Each Mac builds `ClipbaraMAS` Debug in Xcode, which registers it as a development device, and gets the `defaults write` paywall bypass.

**Files:**
- Create: `docs/testing/icloud-sync.md` (each check with pass/fail, latency, and notes)

- [ ] **Step 1:** Optionally import a JSON backup from the DMG app into Copyd through Settings → Backup, to start with real history.
- [ ] **Step 2: Run the spec §13 checklist (items 1-7)**, recording the latency for item 1 (target ≤ 15 s):
  1. A text clip copied on Mac A appears on Mac B within 15 seconds.
  2. Pin, rename and delete on Mac B propagate to Mac A.
  3. Creating, renaming, reordering and deleting a pinboard propagates.
  4. A 5 MB image arrives intact with a thumbnail.
  5. A Universal Clipboard copy ends as a single clip on both Macs.
  6. In CloudKit Console (Development), `Clip` records show only encrypted fields and an asset.
  7. The DMG `Clipbara` target builds, and the existing tests pass.
- [ ] **Step 3: Risk 3.** With Mac B's panel closed, copy on Mac A and check whether Mac B's menu-bar "latest items" updates without opening the panel. Record the result. If pushes do not arrive, the forced fetch on panel open is the documented fallback.
- [ ] **Step 4: Risk 4.** Record whether sync worked without `network.client`. If it did not, add the entitlement in `project.yml`, rebuild, re-run step 2, and note it.
- [ ] **Step 5: Disable and re-enable sync on Mac B.** History must stay intact, with no clip deleted (Review Focus 1).
- [ ] **Step 6: Commit** with `git commit -m "[docs] Record two-Mac iCloud sync verification results"`.
