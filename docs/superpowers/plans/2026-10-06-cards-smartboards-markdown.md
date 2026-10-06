# Cards, Smart Boards and Markdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Work through the tasks one at a time.

**Goal:**
- Cards get Paste-style headers in the source app's color and icon, and the icons sync from the Mac to the iPhone.
- Pinboards fill themselves by type and by topic.
- Markdown can be pasted, converted and rendered.

**Architecture:**
- **Pure units in `Shared/Utilities/`:** `IconColor`, `ContrastPicker`, `SmartKinds`, `TopicPlan`, `MarkdownConverter` and `MarkdownDetector`, all tested in `CopydTests`.
- **New model and record type:** one new synced `@Model AppIdentity` and CloudKit record type `AppIdentity`. Older clients already skip unknown types.
- **Local-only state:** classification is stored in additive attributes that are never mapped, using the same fill-queue pattern as OCR (`ImageTextRecognizer`).

**Tech Stack:** Swift 6 strict concurrency, SwiftUI/AppKit, SwiftData, CloudKit `CKSyncEngine`, FoundationModels (weak, macOS/iOS 26+), NSDataDetector, String Catalogs (en/es), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-10-06-cards-smartboards-markdown-design.md`

## Global Constraints

- **Branch.** `feat/cards-smartboards-markdown`, created from `main` after round 1 is merged, in the worktree /Users/roberto/Code/Clipbara/.claude/worktrees/icloud-sync.
- **Data model.**
  - Never rename existing attributes, store constants, CloudKit zone, record types or fields.
  - New attributes are additive with defaults.
  - New local-only fields are never added to snapshots or the mapper.
  - Sync-layer writes go inside `tracker.suppressing`.
  - After UI mutations, call `try? modelContext.save()`.
- **Secrets.** Clips with `isSensitive` never go to the topic model. Their headers may show the app, but their body stays masked.
- **Strings.** Colors come only from `DesignTokens.Brand`, except the per-app header color, which is computed. Every string has `en` and `es`, and `python3 scripts/check_es.py` must report `0 missing`.
- **Commands.** Run every command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
  - Tests: `xcodebuild test -project Copyd.xcodeproj -scheme CopydTests -destination 'platform=macOS' -derivedDataPath DerivedData`
  - Mac build: `… -scheme Copyd -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build`
  - iOS simulator build: `… -scheme CopydiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build`
  - After editing `project.yml`, run `xcodegen generate`.
  - `CopydTests` lists its sources explicitly, so add new pure files there.
- **Machine load.** The user's Mac must not freeze. Run at most one `xcodebuild` or simulator at a time, and close the simulator when you are done.
- **Never:**
  - run `xcodebuild clean`;
  - delete `DerivedData*`;
  - launch or kill the Mac app;
  - touch the physical iPhone.
- **Simulator.** Runs use `-iCloudSyncEnabled NO`. Uninstall the app afterwards.
- **Commits.** Use the format `[type] what and why`, made with `/usr/bin/git`. No Co-Authored-By line, and never commit `.superpowers/`.

## Review Focus

1. **An `AppIdentity` round-trips through CloudKit without breaking older clients or clip sync.** Its record name is stable per bundle id, and it never references Copyd's own bundle. Pinned by `AppIdentityMapperTests`, plus `testUnknownRecordTypeStillSkippedByOlderLogic`, which asserts that the engine switch's default branch is unchanged.
2. **The header text stays readable on every app color:** white, yellow, black and mid-gray icons. Pinned by `ContrastPickerTests` and `IconColorTests` fixtures.
3. **Prose never lands in Code, and a plain sentence with a phone number lands in Phones & Emails.** Pinned by `SmartKindsTests`.
4. **The topic model never receives secrets, images or files, and a failure retries.** Pinned by `TopicPlanTests`.
5. **Markdown conversion handles nested lists and entities and never crashes on malformed HTML.** A sentence with one `*` is not Markdown. Pinned by `MarkdownConverterTests` and `MarkdownDetectorTests`.

---

### Task 1: App identities and Paste-style headers

**Files:**
- New: `Shared/Models/AppIdentity.swift`, `Shared/Utilities/IconColor.swift` and `Shared/Utilities/ContrastPicker.swift`, plus their tests.
- Sync: `Shared/Sync/SyncRecordMapper.swift` (new type `AppIdentity`), `CloudSyncEngine` (apply and delete for the new type), `LocalChangeTracker`, `RemoteApplier`, and the schema list or `ModelContainer` in every target that opens the store.
- Mac: `ClipboardMonitor` publishes the identity on capture. The header goes in `ClipboardCardView`. `AppIconProvider` falls back to the synced icon.
- iOS: `ClipRow`. Keyboard: the card icon.

**Interfaces:**
- **`AppIdentity`.** Fields as in spec §1. Its record name is `app-` plus a SHA-256 hex of the bundle id, via `AppIdentity.recordName(for bundleId: String) -> String`.
- **`IconColor`.**
  - `IconColor.dominant(rgba: [UInt8], width: Int, height: Int) -> RGB`, using the spec §1 algorithm.
  - `RGB` has `r`, `g` and `b` as `Double` in 0...1, plus `hex`.
- **`ContrastPicker`.**
  - `ContrastPicker.textColor(on: RGB) -> TextTone` (`.light` / `.dark`).
  - `ContrastPicker.ratio(_:_:) -> Double`.
- **Publishing.** `AppIdentityPublisher.needsPublish(existing: Date?, now: Date, bundleId: String, ownBundleId: String) -> Bool` returns true when no identity exists or it is older than 30 days. It returns false when the bundle id is Copyd's own.

**Steps:**
- [ ] Write the failing tests:
  - Icon color fixtures: solid red, white on blue, transparent padding, black glyph on yellow.
  - Contrast: white versus black on yellow, navy and mid-gray.
  - Mapper round-trip and record-name stability.
  - `needsPublish` for each branch.
  - A migration test that fetches `AppIdentity`.
- [ ] Implement the model, mapper, engine and applier wiring. Upload goes through the tracker.
- [ ] Mac capture publish. Render at 128 px off the main thread and compute the color.
- [ ] Mac header. iOS row icon and name. Keyboard icon, decoded at 28 px and cached per bundle.
- [ ] Simulator check: seed an `AppIdentity` and a clip from that bundle (DEBUG argument), then screenshot the iOS row.
- [ ] Verify: the test suite, both builds and `check_es`.
- [ ] Commit: `[feat] Color card headers by source app and sync app icons to iPhone`

### Task 2: Type smart boards

**Files:**
- New: `Shared/Utilities/SmartKinds.swift` and its tests.
- `ClipboardItem` gets `smartKinds: Int = 0` and `smartKindsVersion: Int = 0`, both local-only. An edit resets them.
- A classifier queue, modeled on the OCR fill queue.
- Mac: the nav bar shows the smart boards, and the panel filters by them. `PanelTab` gets `case smart(SmartBoard)`.
- iOS: an Automatic section in `PinboardsView`. Keyboard: the pinboards mode.
- Settings: `smartBoardsEnabled`.

**Interfaces:**
- `enum SmartBoard: String, CaseIterable { links, code, addresses, contacts, images, colors, files, work, shopping, travel, finance, study, social, personal }`.
  - It has `isTopic` and `title` (localized). The spec §2 names are exact.
- `SmartKinds.classify(contentType: ContentType, text: String?) -> Int`. It returns a bitmask of the type boards, uses `CodeDetector` from round 1 and NSDataDetector, and scans only the first 4 KB.
- `SmartKinds.version = 1`.
- `SmartKinds.members(of: SmartBoard, kinds: Int, topic: String?) -> Bool`.

**Steps:**
- [ ] Write the failing tests:
  - Each kind, positive and negative.
  - A sentence with a phone number lands in contacts.
  - Prose is not code.
  - Version bump.
  - An edit resets the bits.
  - The mapper never sees the bits.
  - A migration test with a predicate.
- [ ] Implement the classifier pass. It runs on capture and fills the newest 1,000 clips in batches of 50, with no extensions.
- [ ] Mac nav and filter. Smart boards are marked with ✨, read-only and hidden when empty. ⌥⌘ numbering continues through them.
- [ ] iOS section and keyboard. Add the setting.
- [ ] Simulator: screenshot the Automatic section with seeded clips.
- [ ] Verify: suite, both builds, `check_es`.
- [ ] Commit: `[feat] Sort clips into automatic pinboards by type`

### Task 3: Topic boards with Apple Intelligence

**Files:**
- New: `Shared/Utilities/TopicPlan.swift` and its tests.
- New: `Shared/Services/TopicClassifier.swift` (FoundationModels, weak-linked, app targets only).
- `ClipboardItem` gets `topicRaw: String?` and `topicDone: Bool = false`, both local-only. An edit resets them.
- Settings: `smartTopicsEnabled`, shown only when the model is available.

**Interfaces:**
- `TopicPlan.nextBatch(clips: [TopicPlan.Candidate], limit: 10, window: 1000, skipping: Set<UUID>) -> [UUID]`.
  - It picks text and link clips that are not sensitive and not `topicDone`, newest first.
- `TopicPlan.prompt(previews: [String]) -> String`. Each preview is cut to 300 characters.
- `@Generable enum ClipTopic: String { work, shopping, travel, finance, study, social, personal, other }`.
- Failures leave the clip undone. `other` and an unavailable model mark it done.

**Steps:**
- [ ] Write the failing tests:
  - Batch selection skips secrets, images and files.
  - Previews are truncated.
  - Done versus retry.
  - Reset on edit.
  - The mapper never sees topic fields.
- [ ] Implement the classifier. Follow the round 0 `SuggestionModel` pattern for availability, session and timeout. Run one request per clip, or batch several when the model handles it reliably.
- [ ] Wire the topic boards into the Task 2 UI.
- [ ] Verify the suite, both builds and `check_es`. Check `otool -L` to confirm FoundationModels stays weak.
- [ ] Commit: `[feat] Group clips by topic with on-device Apple Intelligence`

### Task 4: Markdown

**Files:**
- New: `Shared/Utilities/MarkdownConverter.swift` and `Shared/Utilities/MarkdownDetector.swift`, plus their tests.
- `TextTransform` gets `.markdown` and `.richText`, plus applicability.
- Paste funnel: write RTF and plain text for `.richText` (Mac `PasteService`, iOS copy).
- Rendering: Mac `TextCardContent` and Quick Look, iOS `ClipRow`.

**Interfaces:**
- `MarkdownConverter.markdown(fromHTML: String) -> String`
- `MarkdownConverter.markdown(from: NSAttributedString) -> String`
- `MarkdownConverter.attributed(fromMarkdown: String) -> NSAttributedString?`
- `MarkdownDetector.isMarkdown(_ text: String) -> Bool`. It needs at least 2 signals.
- Transform labels:

  | Transform | English | Spanish |
  |---|---|---|
  | `.markdown` | "Markdown" | "Markdown" |
  | `.richText` | "Formatted text" | "Texto con formato" |

- `.richText` is never offered in the keyboard.

**Steps:**
- [ ] Write the failing tests:
  - HTML fixtures: headings, nested lists, links, entities, malformed or unclosed tags, `pre`/`code`.
  - Attributed-string fixtures: bold, italic, link, list, heading by size.
  - Detector positives and negatives.
  - Transform applicability, including keyboard exclusion.
- [ ] Implement the converter. Decode RTF off the main thread.
- [ ] Wire the transforms and the pasteboard writes, then the rendering.
- [ ] Simulator: screenshot an iOS row with seeded Markdown.
- [ ] Verify: the test suite, both builds and `check_es`.
- [ ] Commit: `[feat] Paste as Markdown or formatted text and render Markdown clips`

### Task 5: Merge and install (orchestrator)

- [ ] Run the final whole-branch review, then one fix round.
- [ ] Add `docs/testing/cards-smartboards-markdown.md` and update `CLAUDE.md`. Add the `AppIdentity` Production schema item to the release list.
- [ ] Push, open the PR to `main`, and merge it. The user authorized this on 2026-10-06.
- [ ] Install to `/Applications/Copyd.app` and relaunch. Install on the iPhone if it is reachable.
