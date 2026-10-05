# Clip Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Work through the plan task by task.

**Goal:** Add three things to Copyd:
- Local handling for secrets.
- "Paste/Copy as…" transforms plus clip editing.
- On-device OCR text search for image clips.

**Architecture:**
- Each feature centers on one pure unit in `Shared/`: `SecretDetector`, `TextTransform` and `OCRPlan`. These are tested in `CopydTests`.
- SwiftData attributes are additive and local-only: `isSensitive`, `ocrText`, `ocrDone`.
- Sensitive clips are excluded at the tracker/mapper boundary, so they never upload.

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/AppKit, SwiftData, CloudKit `CKSyncEngine`, Vision, ImageIO, String Catalogs (en/es), XcodeGen. Targets: macOS 14+ and iOS 17+.

**Spec:** `docs/superpowers/specs/2026-10-04-clip-tools-design.md` (approved 2026-10-04).

## Global Constraints

- **Branch.** `feat/clip-tools`, stacked on `feat/smart-suggestions` at db83180.
  - Worktree: /Users/roberto/Code/Clipbara/.claude/worktrees/icloud-sync.
  - Baseline: 388 tests.
- **Data.**
  - Never rename SwiftData attributes, store constants or CloudKit fields.
  - New attributes must be additive and optional, or carry defaults.
  - Sync-layer writes go inside `tracker.suppressing`.
  - After UI mutations, call `try? modelContext.save()`.
- **UI.** Use `DesignTokens.Brand` colors only. Every string needs `en` and `es`, and `python3 /private/tmp/claude-501/-Users-roberto-Code-Clipbara/77c6d156-5a09-4ac7-a103-9784b613e350/scratchpad/check_es.py` must report 0 missing.
- **Commands.** Prefix every one with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
  - Tests: `xcodebuild test -project Copyd.xcodeproj -scheme CopydTests -destination 'platform=macOS' -derivedDataPath DerivedData`
  - Mac build: `… -scheme Copyd -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build`
  - iOS simulator build: `… -scheme CopydiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build` (no provisioning flags)
- **Never:**
  - run `xcodebuild clean`;
  - delete `DerivedData*`;
  - launch or kill the Mac app;
  - touch the iPhone.
- **Commits.** Format `[type] what and why`, made with `/usr/bin/git`. No Co-Authored-By line, and don't commit `.superpowers/`.

## Review Focus

1. **A secret must never reach CloudKit**, including through a later edit, pin or pinboard add. Pinned by `SensitiveSyncTests.testSensitiveClipNeverUploads`, which covers the tracker, the mapper eligibility and `queueEverything`/`uploadableIDs`.
2. **No false positives on everyday text** (normal URLs, UUIDs, git SHAs, order numbers). Pinned by `SecretDetectorTests.testCommonStringsAreNotSecrets`.
3. **Transforms must not crash on odd input:** empty strings, emoji, CRLF, giant JSON. Pinned by `TextTransformTests`.
4. **Editing a clip changes its `contentHash`.** The duplicate rule and sync must treat it as an update, not a new clip. Pinned by a mapper and `RemoteApplier` update test.
5. **OCR must never block the main thread or run in extensions**, and a giant image must stay bounded in memory. Pinned by `OCRPlanTests` (downsample size, batch selection) and by a code review of the queue.

---

### Task 1: Secrets: detect, keep local, auto-delete

**Files:**
- `Shared/Utilities/SecretDetector.swift`, `Tests/SecretDetectorTests.swift`
- `Shared/Models/ClipboardItem.swift` (adds `isSensitive: Bool = false`)
- `Shared/Sync/LocalChangeTracker.swift`, `SyncRecordMapper.swift`, `RemoteApplier.swift` (the `uploadableIDs` pass)
- Capture paths:
  - Mac: `ClipboardMonitor`
  - iOS: `PasteboardCapture` / `saveClipboard` / `captureNewCopy`, `Inbox.drain`, `SaveText`
- Exclusions:
  - `KeyboardFeed`
  - the widget provider
  - the Live Activity latest-clip picker
  - arrival notices
  - suggestion candidates (`SuggestionRanker.candidateClips`)
- Card/row views (masked preview + lock badge)
- Settings, Mac General and iOS Configuración: "Protect secrets" / "Proteger secretos" on by default, plus "Delete secrets after" / "Borrar secretos después de" with 1/5/15/60 min/Never
- `Shared/Utilities/SecretSweeper.swift`

**Interfaces:**
- `enum SecretKind { case apiKey, token, privateKey, card }`
- `SecretDetector.kind(of text: String) -> SecretKind?` and `SecretDetector.mask(_ text: String, kind:) -> String`
  - The mask is the label plus "•••• " plus the last 4 characters.
  - Labels: "API key"/"Clave de API", "Token"/"Token", "Private key"/"Clave privada", "Card"/"Tarjeta".
- `SecretSweeper.expired(clips:[(id, copiedAt, isSensitive)], now:, after:) -> [UUID]` is pure. The sweep runs on a timer every 30 s while the app runs, and once at launch.

**Steps:**
- [ ] Write the failing tests first:
  - each pattern in spec §3, positive and negative;
  - Luhn;
  - `testCommonStringsAreNotSecrets` (URLs with long query strings, UUIDs, 40-character hex SHAs, base64 images, order numbers);
  - masking;
  - sweeper expiry;
  - `SensitiveSyncTests.testSensitiveClipNeverUploads`: the tracker skips it, the mapper reports it ineligible, `uploadableIDs` excludes it, and a pin or edit of a sensitive clip still doesn't upload it.
- [ ] Implement and get every test green.
- [ ] Wire capture, exclusions, UI and settings.
- [ ] Remote clips never arrive with `isSensitive`, because it isn't synced. Detection only runs on the capturing device.
- [ ] Verify: suite, Mac build, iOS simulator build, `check_es`.
- [ ] Commit: `[feat] Keep detected secrets local, masked and short-lived`

### Task 2: Paste/Copy as… and Edit

**Files:**
- `Shared/Utilities/TextTransform.swift`, `Tests/TextTransformTests.swift`
- Mac: card context menu + ⇧⌥Return menu, ⌘E Edit window (`Copyd/Views/EditClipWindow.swift` or similar)
- The pick funnel accepts an optional transformed string
- iOS: row long-press menu ("Copy as…", "Edit"), keyboard card long-press ("Insert as…")
- Edit save path, which updates text and hash and syncs

**Interfaces:**
- `enum TextTransform: CaseIterable { case plain, upper, lower, title, trim, cleanLink, prettyJSON, compactJSON }`
- `func apply(to text: String) -> String?` returns nil when the transform doesn't apply.
- `static func applicable(to text: String, type: ContentType) -> [TextTransform]`
- The clean-link parameter list is exactly the one in spec §2.

**Steps:**
- [ ] Write the failing tests first:
  - every transform;
  - applicability;
  - unicode, emoji, CRLF and empty input;
  - invalid JSON returns nil;
  - clean link keeps non-tracking parameters and fragments.
- [ ] Implement.
- [ ] Mac UI:
  - Paste-as goes through the pick funnel, so direct paste and the `PasteEvent` are recorded.
  - Editing opens a titled window. After an edit is saved, the next pick still restores focus correctly under the existing rule (titled windows opened after the panel).
- [ ] iOS UI, including the keyboard.
- [ ] Saving an edit:
  - Text-like clips only.
  - Store the result as plain text (`contentType` becomes `.plainText` unless it is a URL).
  - Recompute `contentHash` and save.
  - The tracker uploads it as an update.
- [ ] Test: edited clip round-trips as an update.
- [ ] Verify: suite, both builds, `check_es`.
- [ ] Commit: `[feat] Paste or copy a clip as plain text, cleaned or reformatted, and edit clips`

### Task 3: Text in images (OCR)

**Files:**
- `Shared/Utilities/OCRPlan.swift`, `Tests/OCRPlanTests.swift`
- `Shared/Services/ImageTextRecognizer.swift` (Vision, not compiled into the keyboard or widget)
- `ClipboardItem`: add `ocrText: String?` and `ocrDone: Bool = false` (local only, never mapped)
- Mac capture hook; background fill pass on Mac and iPhone (app only)
- Search: Mac panel and iOS History
- UI: "Aa" badge; "Copy text" / "Copiar texto" (Mac context menu, plus ⌥Return; iOS long-press); Quick Look text

**Interfaces:**
- `OCRPlan.nextBatch(clips:[(id, isImage, ocrDone, copiedAt)], limit: 10, window: 300) -> [UUID]` selects the newest image clips not yet done, inside the window.
- `OCRPlan.targetPixelSize = 2048`

**Steps:**
- [ ] Write the failing tests first: batch selection, window, skipping done clips, and the downsample target computation.
- [ ] Implement the recognizer:
  - ImageIO thumbnail at 2048 px, then `VNRecognizeTextRequest`.
  - `.accurate` recognition, with `automaticallyDetectsLanguage` and `recognitionLanguages` `["es", "en"]`.
  - Run at utility priority, off the main actor. Write back on the main actor.
  - Never read `rawData` on main.
- [ ] Exclude `ImageTextRecognizer.swift` from the keyboard, widget and share targets in `project.yml`.
- [ ] Add search matching and the UI.
- [ ] Make sure the mapper never includes `ocrText` or `ocrDone`. Add a test.
- [ ] Verify:
  - suite, both builds, `check_es`;
  - an iOS simulator screenshot of search finding a seeded image by its text (seed a DEBUG image containing the text "Copyd OCR test").
- [ ] Commit: `[feat] Find images by the text in them and copy that text`

### Task 4: Device check and PR (orchestrator + user)

- [ ] Install on the Mac and the iPhone.
- [ ] User checks:
  - a fake Stripe key shows masked, doesn't sync, and auto-deletes;
  - paste a link with `utm_` parameters as "Clean link";
  - ⌘E edits a clip and the change syncs;
  - search finds a screenshot by its text;
  - "Copy text" works.
- [ ] Record results in `docs/testing/`, update `CLAUDE.md`, push, and open a PR stacked on `feat/smart-suggestions`.
