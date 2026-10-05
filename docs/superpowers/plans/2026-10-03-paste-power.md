# Paste Power Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task by task.

**Goal:** Add four features to Copyd:
- Multi-select paste with a separator on the Mac.
- Paste Stack on the Mac.
- File sync from Mac to Mac, with sharing from iPhone.
- An iPhone Live Activity and arrival notifications.

**Architecture:**
- Each feature puts its decision logic in one pure unit in `Shared/` or `Copyd/Utilities/`, tested in `CopydTests`, and keeps its UI and system wiring thin.
- File payloads go through the existing `AssetCrypto` / `CKAsset` path.
- The Live Activity UI lives in the `CopydWidget` extension.

**Tech Stack:** Swift 6 with strict concurrency, SwiftUI, AppKit (`NSPanel`, `CGEvent` tap), SwiftData, CloudKit `CKSyncEngine`, ActivityKit, UserNotifications, XcodeGen. Targets: macOS 14+ and iOS 17+.

**Spec:** `docs/superpowers/specs/2026-10-03-paste-power-design.md`. Paste Stack uses plain ⌘V while it is active; the user chose this on 2026-10-03.

## Global Constraints

- **Branch.** `feat/paste-power` in /Users/roberto/Code/Clipbara/.claude/worktrees/icloud-sync, stacked on `feat/ios-app`. Baseline: 231 tests.
- **Colors and strings.**
  - Colors come only from `DesignTokens.Brand`.
  - Every user-visible string goes in the right `.xcstrings` catalog with `en` and `es`.
  - `python3 /private/tmp/claude-501/-Users-roberto-Code-Clipbara/77c6d156-5a09-4ac7-a103-9784b613e350/scratchpad/check_es.py` must report 0 missing.
- **Mac data safety.**
  - Never rename the store constants or the UserDefaults keys.
  - Sync-layer writes go inside `tracker.suppressing`.
  - After every UI mutation, call `try? modelContext.save()`.
  - Before every paste, call `ClipboardMonitor.skipNextChange()`.
- **Builds and tests.** Prefix every command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
  - Tests: `xcodebuild test -project Copyd.xcodeproj -scheme CopydTests -destination 'platform=macOS' -derivedDataPath DerivedData`
  - Mac: `xcodebuild -project Copyd.xcodeproj -scheme Copyd -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build`
  - iOS simulator: `… -scheme CopydiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build`. Never add `-allowProvisioningUpdates` to this one.
- **Commands never to run:**
  - `xcodebuild clean`
  - deleting `DerivedData*`
  - launching or killing the Mac app (the orchestrator relaunches it)
  - touching the physical iPhone
- **Commits.** Format `[type] what and why`, made with `/usr/bin/git`. No Co-Authored-By line. Never commit `.superpowers/`.

## Review Focus

1. **Paste Stack with an empty stack, or with the HUD up while the user types elsewhere.** ⌘V must behave normally whenever the stack is off or empty. The event tap is removed when the stack ends. Pinned by `PasteStackTests.testEmptyStackPassesThrough`, plus a review of the tap lifecycle.
2. **Multi-select with only images or files selected.** Nothing is pasted, the bar says "Text only — N skipped", and there is no crash. Pinned by `MultiPasteTests.testAllNonTextJoinsToNil`.
3. **A file clip from another Mac whose filenames contain `/`, `..` or control characters.** Files must be written only inside the clip's folder. Pinned by `FileBundleTests.testSanitizesNames`.
4. **11 files, or one 25 MB file.** The clip stays local and never uploads. Pinned by `FileBundleTests.testLimits`.
5. **A notification arrives for a clip that came from this same iPhone through Universal Clipboard.** Only remote inserts are announced. Pinned by `ArrivalNoticeTests` and a review of the hook site.

---

### Task 1: Multi-select paste with a separator (Mac panel)

**Files:**
- `Copyd/Utilities/MultiPaste.swift`, `Tests/MultiPasteTests.swift`
- The panel views: read `Copyd/Views/HistoryPanelView.swift`, `ClipboardCardView.swift` and `NavigationBarView.swift`
- `Copyd/AppState.swift` and `Copyd/Services/PasteService.swift`

**Interfaces:**
- `enum Separator: Codable, Equatable { case newline, space, comma, tab, custom(String) }`, with `var string: String`. `custom` unescapes `\n` and `\t`.
- `enum MultiPaste { static func join(_ items: [ClipboardItem], separator: Separator) -> (text: String, skipped: Int)? }`. Returns nil when no text items remain.
  - Text, rich text and HTML use their plain `textContent`.
  - URLs use their text.
  - Colors use their hex.
  - Images, files and fileURL clips are skipped and counted.

- [ ] Write the failing tests:
  - `testJoinsInSelectionOrder`
  - `testEachSeparator`
  - `testCustomUnescapes`
  - `testSkipsNonText`
  - `testAllNonTextJoinsToNil`
- [ ] Implement the logic and get the tests green.
- [ ] UI: selection state in the panel.
  - ⌘-click toggles a card, ⇧-click selects a range, ⇧←/⇧→ extend the selection.
  - Selected cards get a butter ring and a number badge.
  - With 2 or more selected, show a bar under the top bar: "N selected", a separator menu, and a "Paste" button.
  - Return pastes, ⇧Return pastes as plain text, Esc clears the selection.
  - The last separator is remembered in UserDefaults under the key `multiPasteSeparator`.
- [ ] The paste goes through `PasteService`'s existing plain-text path with the joined string. Call `skipNextChange` first.
- [ ] Verify: run the suite and the Mac build.
- [ ] Commit: `[feat] Select several clips in the panel and paste them with a separator`

### Task 2: Paste Stack (Mac)

**Files:**
- `Copyd/Utilities/PasteStack.swift`, `Tests/PasteStackTests.swift`
- `Copyd/Services/PasteStackController.swift`, which owns the state, the HUD panel and the event tap
- `Copyd/Services/HotkeyManager.swift` (new name `togglePasteStack`, default ⌃⌥⌘C)
- The menu bar menu
- Settings (shortcut recorder and an order toggle)

**Interfaces:**
- `struct PasteStack { enum Order { case fifo, lifo }; mutating func push(_ id: UUID); mutating func popNext() -> UUID?; var count: Int; var isEmpty: Bool }`

**Behavior:**
- While the stack is active, every clip that `ClipboardMonitor` captures is pushed onto it.
- A session `CGEvent` tap (`.cgSessionEventTap`, `keyDown`) handles ⌘V only while the stack is active and not empty:
  1. Swallow the event.
  2. Pop the next item and paste it through `PasteService`, with `skipNextChange` first.
  3. When the stack runs empty, end the stack and remove the tap.
- When the stack is off or empty, the tap does not exist, so ⌘V is never intercepted.
- **HUD:** a non-activating, click-through `NSPanel` at the top center, styled as a brand pill showing "Paste Stack · N". Esc while the HUD is up stops the stack. The HUD is hidden when the stack ends.

- [ ] Write the failing tests:
  - `testFifoOrder`
  - `testLifoOrder`
  - `testEmptyStackPassesThrough` (`popNext` returns nil)
  - `testCountTracksPushPop`
- [ ] Implement and get the tests green.
- [ ] Controller, HUD, tap, hotkey, menu item "Start Paste Stack" / "Stop Paste Stack", and the Settings recorder plus order toggle. Add `es` strings.
- [ ] Verify: suite and Mac build. The tap lifecycle is reviewed by reading the code. The user checks it by hand.
- [ ] Commit: `[feat] Add Paste Stack: copy several things, then paste them in order with ⌘V`

### Task 3: File sync

**Files:**
- `Shared/Utilities/FileBundle.swift`, `Tests/FileBundleTests.swift`
- `Shared/Models/ContentType.swift` (new case `files`)
- `Copyd/Services/ContentTypeClassifier.swift` and `ClipboardMonitor.swift`
- `Shared/Sync/SyncRecordMapper.swift`, `RemoteApplier.swift` and `CloudSyncEngine.swift` (batch eligibility)
- `Copyd/Services/PasteService.swift`
- iOS: `CopydiOS/Views/ClipRow.swift` (file card plus share)

**Interfaces:**
- `struct FileManifestEntry: Codable { name: String; size: Int; uti: String }`
- `enum FileBundle`:
  - `static let maxFileBytes = 20_971_520`
  - `static let maxFiles = 10`
  - `static func encode(_ files: [(name: String, data: Data, uti: String)]) throws -> Data` returns the manifest JSON plus the concatenated data, with offsets taken from the manifest.
  - `static func decode(_ data: Data) throws -> [(name: String, data: Data, uti: String)]`
  - `static func sanitize(_ name: String) -> String` removes path components, `..` and control characters, and returns "file" if the result is empty.
  - `static func withinLimits(sizes: [Int]) -> Bool`

**Behavior:**
- **Capture.** When the pasteboard has file URLs and they pass `withinLimits`, read them inside `startAccessingSecurityScopedResource` as the sandbox requires. Store the result as `.files` with `rawData = FileBundle.encode(…)` and `textContent = names joined by ", "`. A single file has no thumbnail; an image file gets one from its data.
- **Over the limits.** Keep the old `.fileURL` behavior. The clip stays local and never syncs.
- **Sync.** `.files` uploads like large images: an AES-GCM sealed `CKAsset`, plus a `fileManifest` field inside `encryptedValues`. The mapper round-trip test is extended.
- **Paste on a Mac.**
  - Decode the bundle and write the files to `Application Support/Copyd/Files/<clip-id>/<sanitized name>`.
  - Write `NSURL`s to the pasteboard. Call `skipNextChange` first.
  - Delete that folder when the clip is deleted.
- **iPhone.**
  - A file card shows `doc` / `doc.on.doc`, the names (or "N files"), and the total size.
  - Tap: decode into a temp directory, then present a share sheet with the files.
  - The keyboard and the widget skip `.files`.

- [ ] Write the failing tests:
  - `testRoundTrip`
  - `testSanitizesNames`
  - `testLimits`
  - `testDecodeRejectsTruncated`
  - a mapper round trip for `.files`
- [ ] Implement and get the tests green. Then wire up capture, sync, paste and iOS.
- [ ] Verify: suite, Mac build and iOS build. Two-Mac file paste is checked by hand.
- [ ] Commit: `[feat] Sync copied files across Macs and share them from iPhone`

### Task 4: Live Activity and arrival notifications (iPhone)

**Files:**
- `Shared/Utilities/ArrivalNotice.swift`, `Tests/ArrivalNoticeTests.swift`
- `Shared/Utilities/LatestClipActivity.swift` (`ActivityAttributes`, `#if os(iOS)`)
- `CopydWidget/LatestClipLiveActivity.swift`
- `CopydiOS/AppModel.swift`
- `CopydiOS/Views/SettingsView.swift`
- `CopydiOS/Info.plist` (`NSSupportsLiveActivities` = YES)
- `Shared/Sync/CloudSyncEngine.swift`: an iOS hook that reports how many remote clips were inserted, through `onRemoteChanges` or a new callback carrying the inserted ids

**Interfaces:**
- `enum ArrivalNotice { static func content(previews: [String], device: String) -> (title: String, body: String) }`
  - 1 clip → "New clip from your Mac", with the preview cut to 80 characters plus "…".
  - N clips → "N new clips", with the newest preview.
  - Localized `en` and `es`.

**Behavior:**
- **Settings toggles, both off by default:**
  - "Show latest clip on Lock Screen" starts or ends the activity.
  - "Notify me when a clip arrives" requests authorization when switched on.
- **Activity updates.** Update after local saves and after applied remote changes (foreground, or a background push wake). Restart the activity on foreground if it ended, for example after the 8-hour limit.
- **Tapping the activity** opens `copyd://copy/<id>`.
- **Notifications.**
  - Post only when the app is not active and the change came from remote inserts. Never post for local captures.
  - One notification per batch.
  - Tapping it opens History.

- [ ] Write the failing tests:
  - `testSingleClipTitleAndTruncation`
  - `testPluralTitle`
  - `testEmptyPreviewUsesTypeName`
- [ ] Implement and get the tests green. Then the ActivityKit UI (Lock Screen view plus compact and expanded Dynamic Island), the toggles and the notification post.
- [ ] Verify: suite and iOS build. Use a DEBUG harness to show the Lock Screen activity view in the simulator. Push and the Live Activity are checked on the device.
- [ ] Commit: `[feat] Show the latest clip in a Live Activity and notify when clips arrive`

### Task 5: Device and Mac check (orchestrator and user)

- [ ] Install on the iPhone and relaunch the Mac app.
- [ ] The user checks:
  - multi-paste with each separator;
  - Paste Stack order, with ⌘V back to normal afterwards;
  - copy files on the Mac, then share them from the iPhone (two-Mac paste when the second Mac is available);
  - the Live Activity updates when copying on the Mac;
  - a notification with the app in the background.
- [ ] Record the results in `docs/testing/`, update `CLAUDE.md`, then push and open a PR stacked on `feat/ios-app`.
