# iOS Extras Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task by task.

**Goal:** Add four things to the iPhone app: pinboards in the keyboard, App Intents for Shortcuts and Back Tap, a widget, and a Share extension.

**Architecture:**
- The keyboard and the widget open the App Group store read-only through `KeyboardFeed`.
- The app is the only process that writes to the store.
  - App Intents run inside the app.
  - The Share extension writes files to an inbox. The app drains it on launch and on foreground.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, SwiftData, AppIntents, WidgetKit, XcodeGen. iOS 17+.

**Spec:** `docs/superpowers/specs/2026-10-03-ios-extras-design.md`

## Global Constraints

- Every target uses iOS 17.0, Swift 6 and `SWIFT_STRICT_CONCURRENCY: complete`.
- Extensions set `APPLICATION_EXTENSION_API_ONLY: YES`.
- Bundle IDs: `com.robbyfuu.copyd.widget` and `com.robbyfuu.copyd.share`. Both use App Group `group.com.robbyfuu.copyd` and team `TQC76W2BKK`.
- Colors come only from `DesignTokens.Brand`.
- Touch targets are at least 44 pt.
- No extension writes to the SwiftData store.
- Never read `rawData` in a list, grid or widget.
- After every UI mutation, call `try? modelContext.save()`.
- Commits use `[type] what and why`, made with `/usr/bin/git`. No Co-Authored-By line, and never commit `.superpowers/`.
- Build commands, all prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:
  - Tests: `xcodebuild test -project Copyd.xcodeproj -scheme CopydTests -destination 'platform=macOS' -derivedDataPath DerivedData`. The suite has 199 tests at the start of this plan.
  - iOS simulator: `… -scheme CopydiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build`. Never pass `-allowProvisioningUpdates` to this build.
- Never run `xcodebuild clean` or delete `DerivedData*`.
- Never launch or kill the Mac app, and never touch the physical iPhone. The orchestrator installs on the device.
- Simulator launches always pass `-iCloudSyncEnabled NO`. After a simulator session, uninstall the app and shut the simulator down.

## Review Focus

1. **The inbox is drained twice at once**, at launch and on foreground. Each item must be imported exactly once. Pinned by `InboxTests.testDrainImportsOnceAndDeletesFiles`.
2. **A corrupt or partly written inbox file must be skipped and removed**, never crash. Pinned by `InboxTests.testCorruptFileIsSkippedAndRemoved`.
3. **A pinboard is deleted on the Mac while the keyboard has its chip selected.** The feed returns empty and the keyboard falls back to Recent. Pinned by `KeyboardFeedTests.testMissingPinboardReturnsEmpty`.
4. **"Copy Latest Clip" when the history is empty.** It throws a readable error ("No clips yet"), not a crash. Pinned by `LatestClipTests.testEmptyHistory`.
5. **The widget opens with no store yet.** It shows "Open Copyd once" instead of an error. Pinned by the widget provider using `SharedStore.storeExists` (reviewed).

---

### Task 1: Pinboards in the keyboard

**Files:**
- `Shared/Utilities/KeyboardFeed.swift`
- `Tests/KeyboardFeedTests.swift`
- `CopydKeyboard/KeyboardView.swift`
- `CopydKeyboard/KeyboardViewController.swift`

**Interfaces:**
- `KeyboardFeed.Mode` gains `case pinboard(UUID)`. Entries come in `PinboardEntry` order (`order`, or whatever the model uses; read it). The limit is 60, and file clips are excluded.
- `KeyboardFeed.boards(in:) throws -> [KeyboardBoard]`, where `KeyboardBoard` is `{ id, name, colorIndex }`. Boards come in `displayOrder`.

- [ ] Write the failing tests: `testPinboardModeKeepsEntryOrder`, `testPinboardModeExcludesOtherBoards`, `testPinboardModeExcludesFileClips`, `testMissingPinboardReturnsEmpty`, `testBoardsInDisplayOrder`.
- [ ] Implement them and get them green.
- [ ] Replace the header's Recent/Pinned pill with a horizontal `ScrollView` of chips: Recent, Pinned, then one per board.
  - Each board chip shows a dot in its color (`DesignTokens.pinboardDots[colorIndex]`).
  - The active chip gets the `keyCap` fill and shadow. Inactive chips are transparent with `ink2` text.
  - Chips are 44 pt tall, and the scroll indicators are hidden.
  - The wordmark and the "Updated …" text stay. If they don't fit, drop "Updated …" to a second line under the wordmark. Keep the 280 pt total height.
- [ ] If the selected board has disappeared, fall back to Recent.
- [ ] Verify: run the suite and build for the simulator. Seed a pinboard with 2 entries in the DEBUG seed (hashes `seed-*`; pinboard name "Work"; clean it up the same way), then take a screenshot of the harness at `…/scratchpad/x1-chips.png`.
- [ ] Commit: `[feat] Switch between pinboards in the keyboard`

### Task 2: App Intents (Shortcuts, Back Tap, Action button)

**Files:**
- `CopydiOS/Intents/*.swift`
- `Shared/Utilities/LatestClip.swift`
- `Tests/LatestClipTests.swift`
- `CopydiOS/Views/SettingsView.swift`

**Interfaces:**
- `enum LatestClip { @MainActor static func newest(in: ModelContext) throws -> ClipboardItem? }`. Returns the newest clip by `copiedAt`, excluding `.fileURL`.
- `SaveClipboardIntent`: `openAppWhenRun = true`. Its `perform` sets `AppModel.shared.pendingRoute = .saveClipboard` and nothing else. The app's existing route path does the rest.
- `SaveTextIntent(text: String)`: runs in the background. It uses `ClipCapture.text`, then the duplicate rule, then inserts on the app's main context and saves. It returns a dialog: "Saved" / "Already saved" / "Nothing to save".
- `CopyLatestClipIntent`: runs in the background. It copies the newest clip to `UIPasteboard` (images through `PasteboardImage`) and returns `String` output, the text or "Image".
- `CopydShortcuts: AppShortcutsProvider` with these phrases:
  - "Save clipboard in \(.applicationName)"
  - "Copy last clip from \(.applicationName)"
  - "Save text to \(.applicationName)"

- [ ] Write the failing tests: `LatestClipTests.testNewestByDate`, `testSkipsFileClips`, `testEmptyHistory` (returns nil). Also a `SaveTextIntent` core test: factor its logic into a testable `@MainActor static func save(text:in:now:) -> SaveOutcome` and cover the saved, duplicate and empty cases.
- [ ] Implement them and get them green.
- [ ] Add a "Shortcuts & Back Tap" card in Settings with these three steps:
  1. "Open Settings → Accessibility → Touch → Back Tap"
  2. "Choose Double Tap or Triple Tap"
  3. "Pick Save clipboard in Copyd"
- [ ] Verify: run the suite and the simulator build. Screenshot Settings at `x2-settings.png`.
- [ ] Commit: `[feat] Add Shortcuts actions to save the clipboard, save text and copy the last clip`

### Task 3: Widget (`CopydWidget`)

**Files:**
- `project.yml` (new target `CopydWidget`, a `widgetkit-extension` embedded in `CopydiOS`; sources `CopydWidget` + `Shared`, excluding `Shared/Sync/CloudSyncEngine.swift` like the keyboard)
- `CopydWidget/*`
- `Shared/Utilities/QuickRoute.swift` (`case copy(UUID)`)
- `CopydiOS/AppModel.swift` (handle `.copy`, call `WidgetCenter.shared.reloadAllTimelines()` after local saves and remote changes)

**Interfaces:**
- `QuickRoute.copy(UUID)` is parsed from `copyd://copy/<uuid>`. It is accepted from links.

- [ ] Write the failing tests in `QuickRouteTests`: `testParsesCopyRoute`, `testRejectsCopyWithBadUUID`.
- [ ] Implement the widget:
  - Families: `.systemSmall` (1 clip), `.systemMedium` (3 clips) and `.accessoryRectangular` (1 clip preview).
  - Each clip is a `Link(destination: copyd://copy/<id>)`.
  - Use brand tokens and the wordmark at small sizes.
  - The provider reads the store with `allowsSave: false` after `SharedStore.storeExists`. With no store, it shows "Open Copyd once". With an empty history, it shows "Copy something on your Mac".
  - Use timeline policy `.never`.
- [ ] Handle `.copy` in the app: copy the clip with the same path as a tap, then show "Copied".
- [ ] Verify: run the suite and the simulator build (the appex must be embedded in `PlugIns/`). Render each family with a DEBUG preview harness or a snapshot from `ImageRenderer` into `x3-widget-*.png`.
- [ ] Commit: `[feat] Add a widget with your latest clips`

### Task 4: Share extension (`CopydShare`)

**Files:**
- `project.yml` (new target `CopydShare`, an `app-extension` with `NSExtensionPointIdentifier` `com.apple.share-services`, activation rule: text, URL, or 1 image)
- `CopydShare/*`
- `Shared/Utilities/Inbox.swift`
- `Tests/InboxTests.swift`
- `CopydiOS/AppModel.swift` (drain on launch and on `scenePhase == .active`)

**Interfaces:**
- `struct InboxItem: Codable { id: UUID; kind: "text"|"image"; text: String?; payloadFile: String?; createdAt: Date; source: String? }`
- `enum Inbox`:
  - `static func directory(groupContainer:) -> URL`. Returns `<group>/Library/Application Support/Copyd/Inbox` and creates it.
  - `static func write(_:payload:in:) throws`. Writes atomically: write to a temporary file, then rename it to `<id>.json`.
  - `@MainActor static func drain(in context: ModelContext, directory: URL, now: Date) -> Int`. Imports every item through `ClipCapture` and the duplicate rule, keeps `createdAt` as `copiedAt`, sets `sourceAppName` to `source` or "Share", deletes the files, and returns the number of clips imported.
- The drain runs serially on the main actor and guards against running twice at once.

- [ ] Write the failing tests: `testWriteThenDrainImportsText`, `testDrainImportsImageWithThumbnail`, `testDrainImportsOnceAndDeletesFiles`, `testCorruptFileIsSkippedAndRemoved`, `testDuplicateWithin10sSkipped`.
- [ ] Implement them and get them green.
- [ ] Build the Share UI: a SwiftUI sheet with the wordmark, a preview (text up to 4 lines, or a thumbnail), a butter **Save** button and a Cancel button. After saving, show "Saved. It syncs next time you open Copyd." and close after 1.2 s.
- [ ] Verify: run the suite and the simulator build (the appex must be embedded). Screenshot the sheet with a DEBUG harness at `x4-share.png`.
- [ ] Commit: `[feat] Add Share to Copyd`

### Task 5: Device check (orchestrator and user)

- [ ] Build for the device and install. Xcode creates the widget and share App IDs; the user approved this on 2026-10-03.
- [ ] The user checks each item:
  - pinboard chips;
  - Back Tap running "Save clipboard";
  - "Copy last clip";
  - a widget tap;
  - Share from Safari and from Photos, then open Copyd and confirm the Mac receives the clip.
- [ ] Record the results in `docs/testing/ios-app.md`.
- [ ] Update `CLAUDE.md`.
