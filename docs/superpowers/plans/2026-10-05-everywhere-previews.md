# Everywhere and Previews Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Work through the tasks in order.

**Goal:** Copyd can be reached from anywhere on the iPhone (Control Center, the Action button, Lock Screen and Spotlight), and its cards show rich previews (link title and image, highlighted code, large color swatches) on the Mac, iPhone and keyboard.

**Architecture:**
- Each feature has a pure, tested unit in `Shared/Utilities/`: `LinkPreviewPlan`, `SpotlightPlan`, `CodeDetector` and `SyntaxHighlighter`. Thin services wrap the system frameworks: `LinkPreviewFetcher` (LinkPresentation) and `SpotlightIndexer` (CoreSpotlight).
- New SwiftData attributes are additive and local-only, the same pattern as `ocrText`.
- Controls and the Lock Screen widgets live in the existing `CopydWidget` extension.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/AppKit, SwiftData, WidgetKit (`ControlWidget`, iOS 18+), App Intents, CoreSpotlight, LinkPresentation, ImageIO, String Catalogs (en/es) and XcodeGen. Targets: macOS 14+ and iOS 17+.

**Spec:** `docs/superpowers/specs/2026-10-05-everywhere-previews-design.md` (approved 2026-10-05).

## Global Constraints

- **Branch.** `feat/everywhere-previews`, created from `main` at 4a92c79, in the worktree /Users/roberto/Code/Clipbara/.claude/worktrees/icloud-sync. The baseline is 502 tests.
- **Data rules.**
  - Never rename SwiftData attributes, store constants or CloudKit fields. New attributes are additive with defaults.
  - New fields are local-only: never in `ClipSnapshot` or the mapper.
  - Sync-layer writes go inside `tracker.suppressing`. After UI mutations, call `try? modelContext.save()`.
- **Secrets.** `isSensitive` clips are never indexed in Spotlight, never fetched for link previews, and never shown unmasked in any new surface.
- **No URL route for save clipboard.** "Save clipboard" is never reachable through a `copyd://` URL. `CopydiOSApp.onOpenURL` already rejects `.saveClipboard`; keep it that way.
- **UI.**
  - Colors come only from `DesignTokens.Brand`.
  - Every string has `en` and `es`. `python3 scripts/check_es.py` must report `0 missing`.
  - Use neutral Latin American Spanish, with "Configuración".
- **Commands.** Prefix every command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
  - Tests: `xcodebuild test -project Copyd.xcodeproj -scheme CopydTests -destination 'platform=macOS' -derivedDataPath DerivedData`
  - Mac build: `… -scheme Copyd -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build`
  - iOS simulator build: `… -scheme CopydiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build`, with no provisioning flags.
  - After editing `project.yml`, run `xcodegen generate`.
  - `CopydTests` lists its sources explicitly in `project.yml`, so add every new pure file there.
- **Never:**
  - run `xcodebuild clean`;
  - delete `DerivedData*`;
  - launch or kill the Mac app;
  - touch the physical iPhone.
- **Simulator.** Simulator runs are allowed. Launch with `-iCloudSyncEnabled NO` and uninstall afterwards.
- **Commits.** Format `[type] what and why`, with `/usr/bin/git`. No Co-Authored-By line. Never commit `.superpowers/`.

## Review Focus

1. **A secret never reaches Spotlight or a link fetch.** This includes a clip that turns secret after an edit: C4 replaces it with a new id and deletes the old one. Pinned by `SpotlightPlanTests.testSecretsAreNeverIndexed`, `testOldIdIsDeletedWhenReplacedBySecret` and `LinkPreviewPlanTests.testSecretsAreNeverFetched`.
2. **Link preview fields never sync.** An edit clears them, and extensions never fetch. Pinned by `SyncRecordMapperTests.testLinkPreviewIsNeverMapped`, `ClipEditTests.testEditClearsLinkPreview` and a `project.yml` exclusion check.
3. **Prose is never shown as code.** This covers paragraphs, markdown lists, a URL, an email and a phone number. Pinned by `CodeDetectorTests.testProseIsNotCode`.
4. **The Spotlight index follows deletes from every source:** history-limit cleanup, remote deletes, the secret sweep, and account/zone wipes. Pinned by `SpotlightPlanTests.testDeletedIdsAreRemoved` and a wipe-path test.
5. **Highlighting never stalls a card.** Huge text and unterminated strings or comments must finish fast. Pinned by `SyntaxHighlighterTests.testLimitAndUnterminated`, which runs on a 200 KB string in under 50 ms.

---

### Task 1: Controls and Lock Screen widgets

**Files:**
- `CopydWidget/` (new `CopydControls.swift`; `RecentClipsWidget.swift` gets families; new views)
- The intent sharing mechanism: `CopydiOS/Intents/CopydIntents.swift`, with target membership in `project.yml`
- `CopydiOS` route handling for `.search` (the search field gets focus)
- Widget catalog strings

**Interfaces:**
- **Controls** (iOS 18+, behind `if #available(iOS 18, *)` in `CopydWidgets`):
  - `SaveClipboardControl`, kind `com.robbyfuu.copyd.control.save`
  - `SearchControl`, kind `com.robbyfuu.copyd.control.search`
- **Display names:**

  | English | Spanish |
  |---|---|
  | "Save Clipboard" | "Guardar portapapeles" |
  | "Search Copyd" | "Buscar en Copyd" |

- **Intents.**
  - Both controls and the circular widget run App Intents that open the app: `SaveClipboardIntent` (exists) and a new `OpenSearchIntent`. They set `AppModel.shared.pendingRoute` to `.saveClipboard` or `.search` in the app process.
  - Pick the mechanism that compiles in both targets and works: for example a `WIDGET_EXTENSION` compilation condition around the app-only `perform` body, or `OpenIntent`. Verify it in the simulator.
- **Lock Screen.** The new `LockScreenSaveWidget` uses kind `SaveClipboard` and the `.accessoryCircular` family. `RecentClipsWidget` adds `.accessoryInline`, which shows the latest clip preview, is `privacySensitive`, and excludes secrets through the existing `KeyboardFeed`.

**Steps:**
- [ ] Write a failing test: `QuickRouteTests.testSaveClipboardURLIsRejectedByAppPolicy`. Extract the existing `route != .saveClipboard` check into a tiny pure `QuickRoute.allowsURL(_:) -> Bool` and test it. Also test that `.search` is allowed.
- [ ] Implement the intents, the controls and the widgets.
- [ ] Make `.search` focus the History search field.
- [ ] Simulator check (iOS 18+ runtime):
  - The controls appear in the Control Center gallery.
  - Running `SaveClipboardIntent` and `OpenSearchIntent` opens the app on the right route. Use `xcrun simctl` and the Shortcuts URL or app-intent invocation you can drive headless. If a step can't be driven headless, say so in the report.
  - Screenshot the circular and inline widgets with the existing DEBUG `-CopydWidgetPreview` harness, extended for the new families.
- [ ] Verify: the test suite, the Mac build, the iOS simulator build and `check_es`.
- [ ] Commit: `[feat] Add Control Center and Lock Screen shortcuts to save and search clips`

### Task 2: Link previews

**Files:**
- `Shared/Utilities/LinkPreviewPlan.swift`, `Tests/LinkPreviewPlanTests.swift`
- `Shared/Services/LinkPreviewFetcher.swift`: app targets only. Excluded from the keyboard, widget and share targets in `project.yml`.
- `ClipboardItem`: add `linkTitle: String?`, `@Attribute(.externalStorage) linkImageData: Data?` and `linkPreviewDone: Bool = false`. All local-only.
- `ClipEdit`: clears the three fields when `textContent` changes.
- `Copyd/Copyd.entitlements`: add `com.apple.security.network.client` through the `project.yml` entitlements properties.
- **Display:**
  - Mac `LinkCardContent` and Quick Look
  - iOS `ClipRow`
  - `KeyboardFeed`: the preview text uses the title
  - Search: Mac `SearchState`, iOS `HistoryView`
- **Settings:** "Link previews" / "Vistas previas de links", key `linkPreviewsEnabled`, default true. On the Mac it lives in General (`.standard`). On iOS it goes in the App Group defaults, so the keyboard and widget can read it.

**Interfaces:**
- `LinkPreviewPlan.nextBatch(clips: [LinkPreviewPlan.Candidate], limit: Int = 5, window: Int = 300, skipping: Set<UUID>) -> [UUID]` picks the newest link clips that are not done, not sensitive, and have an `http`/`https` URL.
- `LinkPreviewPlan.Candidate` has the fields `id`, `isLink`, `isSensitive`, `isDone`, `copiedAt` and `url: String?`.
- `LinkPreviewPlan.outcome(for error: Error) -> Outcome` returns `.retry` for offline or timed-out errors (`NSURLErrorDomain` `notConnectedToInternet`, `timedOut`, `networkConnectionLost`, and `LPError` timeout) and `.done` for anything else.
- Constants: `targetPixelSize = 640`, `jpegQuality = 0.7`, `timeout: TimeInterval = 10`.
- `LinkPreviewFetcher`:
  - **Runs:** on capture (Mac), in the fill pass at launch and on remote changes (Mac and iOS), and while iOS is in the foreground. It stops when the app goes to the background.
  - **Execution:** one pass at a time, never on the main actor except for the write-back. The OCR queue (`ImageTextRecognizer`'s fill) is the reference.
  - **Writes:** a tracked pre-save, then a suppressed save, the same as OCR.

**Steps:**
- [ ] Write the failing tests:
  - `LinkPreviewPlanTests`: batch, window, skipping secrets and non-http URLs, done versus retry, and the skip set.
  - `SyncRecordMapperTests.testLinkPreviewIsNeverMapped`.
  - `ClipEditTests.testEditClearsLinkPreview`.
  - A `StoreMigrationTests` predicate fetch on `linkPreviewDone == false`.
- [ ] Implement the plan, the fetcher, the attributes, the entitlement and the settings.
- [ ] Display and search.
- [ ] Simulator check: seed a link clip (DEBUG arg) to a stable page such as `https://www.apple.com`, then screenshot the iOS row showing the title and image.
- [ ] Verify: suite, both builds, `check_es`. Confirm with `otool -L` or by checking the target sources that LinkPresentation is not in the keyboard, widget or share targets.
- [ ] Commit: `[feat] Show link titles and images on cards`

### Task 3: Spotlight on iPhone and iPad

**Files:**
- `Shared/Utilities/SpotlightPlan.swift`, `Tests/SpotlightPlanTests.swift`
- `CopydiOS/Services/SpotlightIndexer.swift` (iOS app only)
- `CopydiOSApp` / `AppModel`: wiring, continuing the user activity, the wipe path
- iOS `SettingsView`: the toggle
- Catalog strings

**Interfaces:**
- `SpotlightPlan.Input` fields: `id`, `contentType`, `text` (prefix), `ocrText`, `linkTitle`, `fileNames: [String]`, `hasThumbnail`, `isSensitive`.
- `SpotlightPlan.record(for: Input) -> SpotlightRecord?`
  - `SpotlightRecord` fields: `id: UUID`, `title: String` (80 characters at most), `summary: String` (300 characters at most) and `thumbnailSource: .image | .link | none`.
  - It follows the spec §3 table exactly.
  - The "Image" title uses `String(localized: "Image")`, which is "Imagen" in Spanish.
- `SpotlightPlan.changes(saved: [Input], deleted: [UUID]) -> (upsert: [SpotlightRecord], delete: [UUID])`. A saved clip whose `record` is nil becomes a delete.
- `SpotlightIndexer`:
  - **Domain and identifiers:** domain `clips`, unique id = the clip's UUID string.
  - **Triggers:**
    - `ModelContext.didSave` on the main context. Use the inserted, updated and deleted identifiers, then fetch the snapshots.
    - A full rebuild when `spotlightIndexVersion` (App Group defaults) is not 1, or when the toggle turns on.
    - A full delete when the toggle turns off and on the local-mirror wipe.
  - **Setting:** `spotlightEnabled` (App Group), default true. "Show in Spotlight" / "Mostrar en Spotlight".
  - **Tapping a result:** `onContinueUserActivity(CSSearchableItemActionType)` routes to `QuickRoute.copy(id)`.

**Steps:**
- [ ] Write the failing tests: each type in or out, `testSecretsAreNeverIndexed`, `testOldIdIsDeletedWhenReplacedBySecret` (the C4 replace), `testDeletedIdsAreRemoved`, and the OCR text removed → delete transition.
- [ ] Implement the indexer, the wiring, the setting and the wipe path.
- [ ] Simulator check: seed clips, let the indexer run, then confirm through `CSSearchableIndex` fetch or a Spotlight query (`CSSearchQuery`) in a DEBUG harness that the seeded text is found and a seeded secret is not. Screenshot if it can be driven.
- [ ] Verify: suite, both builds, `check_es`.
- [ ] Commit: `[feat] Find and copy clips from Spotlight on iPhone and iPad`

### Task 4: Code highlighting and color swatches

**Files:**
- `Shared/Utilities/CodeDetector.swift` and `Shared/Utilities/SyntaxHighlighter.swift`, plus tests for both
- `Shared/Design/DesignTokens+Brand.swift`, which gets new dynamic tokens:

  | Token | Light | Dark |
  |---|---|---|
  | `codeKeyword` | 0x7A3EB1 | 0xC792EA |
  | `codeString` | 0x2E7D32 | 0xA5D6A7 |
  | `codeComment` | 0x8A8F98 | 0x7F848E |
  | `codeNumber` | 0xB35C00 | 0xF6B26B |

- Mac `TextCardContent`, Quick Look, iOS `ClipRow`
- Mac `ColorCardContent`, iOS `ClipRow` color layout

**Interfaces:**
- `CodeDetector.isCode(_ text: String) -> Bool`
- `SyntaxHighlighter.tokens(in text: String, limit: Int = 2048) -> [CodeToken]`
  - `CodeToken` is `(range: Range<String.Index>, kind: CodeTokenKind)`, with `CodeTokenKind` one of `keyword`, `string`, `comment`, `number`.
  - Comments: `//`, `#`, `/* */`, `--`. Strings: `'`, `"`, `` ` ``.
  - Keywords come from one combined set (Swift, JS/TS, Python, Go, Rust, SQL, shell).
- The cache lives in an `NSCache` keyed by `contentHash`, so the highlighter never recomputes per `body` evaluation.
- `ColorFormat.rgbString(hex:) -> String?` returns `"RGB 52, 120, 246"`. Reuse the existing hex parsing if there is any.

**Steps:**
- [ ] Write the failing tests:
  - `testProseIsNotCode`: a paragraph, a markdown list, a URL, an email, a phone number.
  - Positives: Swift, JS, Python, JSON, shell, SQL.
  - Highlighter kinds, nested and escaped quotes.
  - `testLimitAndUnterminated`: 200 KB in under 50 ms.
  - `rgbString`.
- [ ] Implement, then wire the Mac card, Quick Look and the iOS row.
  - Code is monospaced and colored.
  - The search highlight stays on top.
  - Colors come from the tokens.
- [ ] Simulator check: screenshot an iOS row with seeded code and a seeded color. Check the Mac with the build only.
- [ ] Verify: suite, both builds, `check_es`.
- [ ] Commit: `[feat] Highlight code and show large color swatches on cards`

### Task 5: Merge and install (orchestrator)

- [ ] Do a final whole-branch review and one fix round.
- [ ] Add `docs/testing/everywhere-previews.md`, which lists the pending device checks, and update `CLAUDE.md`.
- [ ] Push, open a PR to `main`, and merge it. The user authorized merging to `main` on 2026-10-05.
- [ ] Install the Mac app to `/Applications/Copyd.app` and relaunch it. Install on the iPhone if it is reachable.
