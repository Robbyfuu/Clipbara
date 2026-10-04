# Copyd: iCloud clipboard sync (Mac ↔ Mac, iOS-ready)

- Date: 2026-10-01
- Status: Draft, pending review
- Branch: `feat/icloud-sync`

## 1. Context

This repository is a fork of Clipbara (GPL-3.0, upstream `mobrava/Clipbara`). The fork becomes **Copyd**, a clipboard manager whose history follows the user across Apple devices, in the spirit of Paste.

The work is split into two sub-projects, each with its own spec, plan and implementation:

1. **This spec:** Mac ↔ Mac sync through CloudKit, with a record schema an iOS client can adopt unchanged.
2. **Later spec:** the iOS/iPadOS app (keyboard and share extensions), which reuses the CloudKit schema defined here.

Distribution path: personal use first (Debug build, CloudKit Development environment), Mac App Store later.

## 2. Identity

| Item | Value |
|---|---|
| Product name | Copyd |
| Bundle ID (sync build) | `com.robbyfuu.copyd` |
| iCloud container | `iCloud.com.robbyfuu.copyd` (permanent: containers cannot be deleted) |
| Team ID | `TQC76W2BKK` (from the local "Apple Distribution" certificate; confirm in the developer portal before creating the container) |

The visible rename (display name, strings, icon) is out of scope for this spec.

## 3. Goals and success criteria

1. A clip copied on Mac A appears in Mac B's history within 15 seconds when both Macs are online and signed in to the same Apple ID.
2. Pinning, renaming and deleting clips, and creating, renaming, reordering and deleting pinboards, propagate the same way.
3. Clip content is end-to-end encrypted. The CloudKit server stores only ciphertext and record UUIDs.
4. Existing local history survives the upgrade. The schema change is a lightweight migration.
5. The DMG target (`Clipbara`) still builds and behaves exactly as upstream.

## 4. Non-goals

- iOS/iPadOS app (sub-project 2).
- Syncing file clips (`.fileURL`). They store a local path, not file content, and stay local.
- Syncing `ExcludedApp`, settings or `historyLimit`.
- Sharing clips with other users.
- Rename and branding of the app UI.
- App Store submission, and resolving the GPL-3.0 license with upstream. This must be settled before any App Store release.
- A "delete my iCloud data" control.

## 5. What syncs

| Local model | Syncs | Notes |
|---|---|---|
| `ClipboardItem` | Yes | Except `.fileURL` clips and clips whose `rawData` exceeds 20 MB. A `.files` clip (copied files) syncs up to 48 MB of file data in total: at most 10 files of 20 MB each, and 49 MB with its manifest. A copy over any of these limits stays a local `.fileURL` clip. |
| `Pinboard` | Yes | |
| `PinboardEntry` | Yes | Only when its clip is synced. Entries pointing at a local-only clip stay local. |
| `ExcludedApp` | No | Per-device choice. |
| `thumbnailData` | No | Each device regenerates it from `rawData`. |

## 6. Local schema change

Each of `ClipboardItem`, `Pinboard` and `PinboardEntry` gains one attribute:

```swift
var syncSystemFields: Data?   // CKRecord system fields, archived with encodeSystemFields(with:)
```

It is optional with no default, so SwiftData migrates the store lightweight. No data moves, and `TransferService`'s backup format is unchanged. The DMG target shares the model files and carries the unused attribute; that is harmless.

## 7. CloudKit schema

- Database: the user's private database.
- Zone: `Clipboard` (custom zone, required for `CKSyncEngine` change tracking).
- `recordName` = the model's existing `UUID`.
- Every content field lives in `encryptedValues`. Only references and the assets are plain fields.

### `Clip`

| Field | Storage | Type |
|---|---|---|
| `contentType` | encrypted | String (`ContentType.rawValue`) |
| `textContent` | encrypted | String?, present when its UTF-8 form is ≤ 256 KB |
| `userTitle` | encrypted | String? |
| `sourceAppName` | encrypted | String? |
| `sourceAppBundleId` | encrypted | String? |
| `contentHash` | encrypted | String |
| `copiedAt` | encrypted | Date |
| `isPinned` | encrypted | Int64 (0/1) |
| `rawData` | encrypted | Data, present when `rawData` ≤ 256 KB |
| `assetKey` | encrypted | Data (32 bytes), present when `rawData` or `textContent` > 256 KB |
| `payload` | plain | `CKAsset`, present when `rawData` > 256 KB |
| `textPayload` | plain | `CKAsset`, present when `textContent` (UTF-8) > 256 KB |
| `fileManifest` | encrypted | Data?, JSON `[{name, size, uti}]`, present only for `.files` clips |
| `fromUniversalClipboard` | encrypted | Int64 (0/1): the Mac captured the copy from Universal Clipboard. Missing on older records, read as 0 |

`payload` holds `rawData` sealed with AES-GCM (CryptoKit) under a random per-clip key stored in `assetKey`. CloudKit encrypts assets at rest on its own, but only Advanced Data Protection makes that end-to-end; sealing the file first keeps clip content end-to-end encrypted for every user.

`textPayload` holds a large `textContent` sealed the same way under the same `assetKey`; without it, a text clip over about 1 MB would carry its full text inline and exceed the record limit.

The 256 KB threshold keeps every record well under CloudKit's 1 MB record limit.

Size caps: a clip's `rawData` is at most 20 MB, except a `.files` clip, whose bundle holds at most 48 MB of file data (10 files of 20 MB each, 48 MB in all) plus its manifest, 49 MB at most. That keeps every `payload` under CloudKit's documented 50 MB asset limit and inside one 50 MB upload batch. A larger copy stays local. The receiving device stores `fileManifest` with the clip (`fileManifestData`), so its cards show names and sizes without opening `payload`.

`rawData` bytes are platform-neutral, so an iOS client can decode them: UTF-8 text for `plainText`, `url`, `html` and `color` (hex), RTF for `richText`, and the captured TIFF/PNG/JPEG bytes for `image`.

### `Pinboard`

| Field | Storage | Type |
|---|---|---|
| `name` | encrypted | String |
| `displayOrder` | encrypted | Int64 |
| `createdAt` | encrypted | Date |

### `PinboardEntry`

| Field | Storage | Type |
|---|---|---|
| `clip` | plain | `CKRecord.Reference`, action `.deleteSelf` |
| `pinboard` | plain | `CKRecord.Reference`, action `.deleteSelf` |
| `displayOrder` | encrypted | Int64 |
| `addedAt` | encrypted | Date |

References expose only UUIDs. With `.deleteSelf`, deleting a clip or a pinboard on the server also deletes its entries.

## 8. Architecture

New folder `Clipbara/Sync/`.

### Pure units (no AppKit, no SwiftData, unit-tested in the unhosted target)

| Unit | Responsibility |
|---|---|
| `SyncRecordMapper` | `ClipSnapshot` / `PinboardSnapshot` / `EntrySnapshot` value types ↔ `CKRecord`. Applies the inline-or-asset rule and the eligibility rule (no `.fileURL`, ≤ 20 MB, or ≤ 49 MB for a `.files` bundle). |
| `AssetCrypto` | AES-GCM seal and open of the asset payload with a per-clip key. |
| `DuplicateRule` | Decides whether two clips are duplicates and which one survives. |

### Integration units

| Unit | Responsibility |
|---|---|
| `LocalChangeTracker` | The single capture point for local changes. Observes `ModelContext.willSave` on the main context, reads `insertedModelsArray`, `changedModelsArray` and `deletedModelsArray`, and turns synced models into `.saveRecord` / `.deleteRecord` pending changes. Skips the IDs the sync layer is writing (an ignore set), so remote changes never echo back. |
| `CloudSyncEngine` | `@MainActor final class` conforming to `CKSyncEngineDelegate`. Owns the `CKSyncEngine`, persists its state, builds upload batches, applies fetched changes to SwiftData, handles errors and account changes, and exposes a status for the UI. |
| Settings | A "Sync with iCloud" toggle and a status line in `GeneralSettingsTab`. |

### Build gating

- New compilation condition `CLOUDSYNC`, set only on the `ClipbaraMAS` target.
- The `Sync/` files compile in both targets; CloudKit links fine without the entitlement as long as no container is created.
- Only the wiring is behind `#if CLOUDSYNC`: engine creation in `AppState.start` and the Settings section. The DMG target never creates a container, so it needs no iCloud entitlement.

### Shared helper

`ClipboardMonitor.generateThumbnail(from:)` becomes `static` (internal) so `CloudSyncEngine` can build thumbnails for incoming images. This is the only change to existing services beyond the wiring.

## 9. Data flow

### Local → cloud

1. A change happens: the monitor captures a clip, the user pins, renames or deletes, `historyLimit` cleanup runs, or a backup import runs.
2. The code calls `save()`, as the project rules require after every mutation.
3. `LocalChangeTracker` queues the pending change in `syncEngine.state`.
4. `CKSyncEngine` decides when to send (automatic sync).
5. `nextRecordZoneChangeBatch` builds each record from the model's current state. It starts from the cached `syncSystemFields` when present, which avoids false conflicts. Pending changes are ordered so clips and pinboards come before entries.
6. On `sentRecordZoneChanges`: store the new `syncSystemFields`, delete the temporary asset files, and handle failures (section 11).

### Cloud → local

1. A silent push arrives, or the panel opens (forced `fetchChanges()`, at most once every 30 seconds).
2. On `fetchedRecordZoneChanges`, modifications are applied as upserts by UUID: clips, then pinboards, then entries.
3. If a record has a local pending save, its fields are **not** overwritten; only `syncSystemFields` is updated, and the local change uploads afterward (local pending change wins).
4. An entry whose clip or pinboard has not arrived yet is held in memory and retried at `didFetchChanges`. It is dropped with a log line if its target still does not exist.
5. Incoming clips go through `DuplicateRule`. Incoming images get a regenerated thumbnail.
6. The sync layer saves with its IDs in the ignore set, then calls `clipboardMonitor.refreshLatestItems()`.
7. Deletions always apply: they remove the local model and any pending save for it (a remote deletion beats a local edit). Deleting a pinboard cascades its entries locally.

### `historyLimit` cleanup

Cleanup deletions sync like any other deletion. This keeps the cloud bounded and keeps a newly added device from downloading thousands of clips. As a result, the shared history is capped by the smallest `historyLimit` among the user's devices. Pinned clips are never deleted by cleanup.

### Enabling sync

1. A toggle (`UserDefaults` key `iCloudSyncEnabled`, default off).
2. On first enable: queue `.saveZone(Clipboard)` and a `.saveRecord` for every eligible local clip, pinboard and entry.
3. The engine fetches whatever other devices already uploaded. `DuplicateRule` merges the overlap.

Disabling stops the engine and deletes its state file. Local data and cloud data are both kept.

### State persistence

`CKSyncEngine.State.Serialization` is written on every `.stateUpdate` to `SyncState.data`, next to the SwiftData store (the same Application Support directory `StoreManager.resolveStoreURL()` uses). Pending changes live inside that state, so they survive relaunches.

## 10. Duplicate rule (Universal Clipboard)

When the user copies on Mac A, Handoff also places the content on Mac B's pasteboard, and Mac B's monitor captures it as a new clip. Without a rule, the shared history would show it twice.

- **Duplicates:** two clips with the same `contentHash` whose `copiedAt` values are at most 60 seconds apart.
- **Survivor:** the clip whose `id.uuidString` sorts first. Every device applies the same rule, so all devices converge on the same survivor.
- **Merge:** survivor `isPinned` = `a || b`; survivor `userTitle` = survivor's, or the other's when the survivor's is nil; survivor `fromUniversalClipboard` = `a && b`, so a real copy wins over its relayed twin. The loser's pinboard entries move to the survivor (an entry is deleted instead when the survivor is already in that pinboard).
- **Loser:** deleted locally, with `.deleteRecord` queued. An `unknownItem` answer means another device already deleted it, which is fine.
- **When it runs:** for each incoming clip, against local clips with the same hash.

Because the rule compares `copiedAt` values rather than arrival time, it also merges the duplicates Universal Clipboard already left in both histories when sync is enabled for the first time.

## 11. Error handling

| Event | Behavior |
|---|---|
| `.accountChange` sign-in | If sync is enabled and no state exists, run the first-enable flow. |
| `.accountChange` sign-out or switch | Turn sync off, delete the engine state, keep local history. Status: "iCloud account changed". Never mix two accounts' data without the user re-enabling sync. |
| Network or service errors (`networkFailure`, `networkUnavailable`, `zoneBusy`, `serviceUnavailable`, `requestRateLimited`, `notAuthenticated`) | `CKSyncEngine` retries on its own. |
| `quotaExceeded` | Status: "iCloud storage full". Changes stay queued; the app keeps working locally. |
| `serverRecordChanged` | Store the server's system fields, keep the local values, re-queue the save (local pending change wins). |
| `zoneNotFound` | Queue `.saveZone`, clear `syncSystemFields` for the record, re-queue the save. |
| `unknownItem` on save | Another device deleted the record: delete it locally and drop the pending save (a remote deletion beats a local edit). |
| Zone deleted, reason `encryptedDataReset` | The user reset their iCloud Keychain: clear all `syncSystemFields`, re-create the zone, queue every eligible record. |
| Zone deleted, reason `deleted` or `purged` | The user removed the data from iCloud settings: turn sync off, delete state, keep local data. |
| Record that fails to decrypt or decode | Skip it, log it, keep going. Never crash. |

Status values shown in Settings: up to date (with time of last sync), syncing, iCloud account unavailable, iCloud storage full, account changed (sync off), and error (last message).

## 12. Signing and entitlements (`ClipbaraMAS` target)

- `PRODUCT_BUNDLE_IDENTIFIER`: `com.robbyfuu.copyd`.
- `DEVELOPMENT_TEAM`: `TQC76W2BKK` for all configurations, with automatic signing. The Release config's manual signing with upstream's team and profile is replaced; App Store signing is set up again at submission time.
- `SWIFT_ACTIVE_COMPILATION_CONDITIONS`: `APPSTORE CLOUDSYNC $(inherited)`.
- Entitlements added: `com.apple.developer.icloud-container-identifiers` = `[iCloud.com.robbyfuu.copyd]`, `com.apple.developer.icloud-services` = `[CloudKit]`, `com.apple.developer.aps-environment` = `development`.
- `com.apple.security.network.client` is **not** added, because CloudKit traffic goes through the system daemon. It is added only if the first spike proves it is needed.
- `NSApplication.shared.registerForRemoteNotifications()` is called at startup when sync is enabled.

### Personal use

- Build the `ClipbaraMAS` scheme in Debug on each Mac. Building in Xcode on a Mac registers that Mac as a development device, which a Development-signed build needs to launch.
- The upstream paywall stays in the code. In Debug builds it is bypassed without code changes with `defaults write com.robbyfuu.copyd ClipbaraDebugOriginalAppVersion 1.0`.
- The Debug build uses the CloudKit **Development** environment. Data created there does not carry over to Production.

### Before an App Store release (outside this spec)

- Deploy the schema to Production in CloudKit Console.
- Set `aps-environment` to `production`.
- Resolve licensing with upstream.

## 13. Testing

### Unit tests (TDD, `ClipbaraTests`, unhosted)

The `Sync/` pure files are added to the test target sources in `project.yml`, like the existing utilities.

- `SyncRecordMapper`
  - Round trip for each synced content type.
  - 256 KB boundary: exactly 256 KB is inline, one byte more becomes an asset.
  - 20 MB cap: a larger clip is ineligible.
  - `.fileURL` clips are ineligible.
  - No content field is written outside `encryptedValues`.
- `AssetCrypto`
  - Round trip.
  - Opening fails on tampered ciphertext.
  - Opening fails with the wrong key.
- `DuplicateRule`
  - 59 seconds apart merges; 61 seconds does not.
  - Different hashes never merge.
  - The survivor does not depend on argument order.
  - Pin and title merge as specified.

### Integration tests (in-memory `ModelContainer`)

The model files are added to the test target sources.

- An insert, a change and a delete each produce the right pending change.
- Saves made by the sync layer (IDs in the ignore set) produce none.
- An unsynced type (`ExcludedApp`) produces none.

### Real verification (two Macs, same Apple ID)

1. A text clip copied on Mac A appears on Mac B within 15 seconds.
2. Pin, rename and delete on Mac B propagate to Mac A.
3. Creating, renaming, reordering and deleting a pinboard propagates.
4. A 5 MB image arrives intact with a thumbnail.
5. A Universal Clipboard copy ends as a single clip on both Macs.
6. In CloudKit Console (Development), `Clip` records show only encrypted fields and an asset.
7. The DMG `Clipbara` target builds, and the existing tests pass.

## 14. Risks validated first

The implementation plan starts with a spike that checks these before any feature code:

| # | Assumption | Fallback if false |
|---|---|---|
| 1 | `ModelContext.willSave` exposes deleted models, with readable `id`, on macOS 14. | Explicit tracker calls at the deletion sites (`ClipboardCardView`, `NavigationBarView`, `PinboardGridView`, `ClipboardMonitor.cleanupOldItems`). |
| 2 | A `@MainActor` class can conform to `CKSyncEngineDelegate` under Swift 6 strict concurrency. | An `actor` delegate that hops to the main actor only to touch SwiftData. |
| 3 | Silent pushes reach a sandboxed `MenuBarExtra` app. | The forced fetch on panel open still keeps the visible history current. |
| 4 | CloudKit works in the sandbox without `network.client`. | Add the entitlement. |

Other known limits:

- **iCloud storage:** large image histories consume the user's iCloud storage, for example 500 screenshots at 5 MB is about 2.5 GB. No mitigation in this spec beyond the 20 MB per-clip cap.
- **Clock skew:** if two Macs' clocks differ by more than 60 seconds, the duplicate rule misses. NTP makes this unlikely.
- **Bundled unsaved edits:** a user edit that is still unsaved when the sync layer saves the same model would be skipped by the tracker. The project rule of saving right after every mutation keeps this window closed.
