# Smart Suggestions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Work through the plan one task at a time.

**Goal:** When the Mac panel opens, show first the 3 clips the user is most likely to paste into the current app. The ranking learns from habit, and on macOS 26+ an on-device Apple Intelligence model reranks it.

**Architecture:**
- A local-only `PasteEvent` log, recorded at the single pick funnel.
- A pure `SuggestionRanker` scores the candidates.
- The History row shows the suggestions first, with a "Suggested" chip.
- A Foundation Models rerank sits behind an availability check and a 600 ms timeout, and falls back to the habit order.

**Tech Stack:** Swift 6 with strict concurrency, SwiftUI and AppKit, SwiftData, FoundationModels (macOS 26+). Deployment target macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-04-smart-suggestions-design.md`. It was revised in commit 7dcc7e6: stage 2 uses app context only, and suggestions appear inline.

## Global Constraints

- **Branch:** `feat/smart-suggestions`, branched from `feat/paste-power` (PR #3) at 4273a36.
- **Platform:** Mac only. The iOS targets must still build unchanged.
- **Privacy:**
  - `PasteEvent` is local only. Never sync it.
  - `LocalChangeTracker` and the CloudKit mapper must never see it.
  - The model only runs on device. Previews sent to it are capped at 120 characters. Never read `rawData`.
- **Code conventions:**
  - Use `DesignTokens.Brand` colors only.
  - Every user-visible string gets `en` and `es`, and `check_es.py` must report 0 missing.
  - After every SwiftData mutation, call `try? modelContext.save()`.
  - Respect the `@Query` lifecycle rule inside `NSHostingView`.
- **Commands to run:**
  - Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Copyd.xcodeproj -scheme CopydTests -destination 'platform=macOS' -derivedDataPath DerivedData`. Baseline: 360 tests.
  - Builds: Mac (`-derivedDataPath DerivedData -allowProvisioningUpdates`) and iOS simulator (no provisioning flags).
- **Never:**
  - run `xcodebuild clean`;
  - delete `DerivedData*`;
  - launch or kill the Mac app;
  - touch the iPhone.
- **Commits:** format `[type] what and why`. No Co-Authored-By line. Don't commit `.superpowers/`.

## Review Focus

1. **No history yet** (fresh install, or a new app). Show recency-only suggestions, or hide the row. Never show junk scores. Pinned by `SuggestionRankerTests.testEmptyHistoryFallsBackToRecency`.
2. **A deleted clip that still has paste events.** It must never be suggested, and the panel must not crash. Pinned by `testDeletedClipsAreNotSuggested`, and by the cascade or cleanup on delete.
3. **⌘1–9 numbering with suggestions shown.** The numbers follow the cards in the order they are displayed. Pinned by an update to `QuickPasteShortcut` or the panel test.
4. **The model returns out-of-range, duplicate or more than 3 indices.** Validate and fall back. Pinned by `SuggestionPicksTests`.
5. **The model is unavailable, or slower than 600 ms.** The panel never waits: it shows the habit order. Pinned by a pure `rerank(timeout:)` helper test with a fake async source.

---

### Task 1: Paste history and the habit ranker

**Files:**
- `Copyd/Models/PasteEvent.swift` (Mac-only `@Model`)
- the Mac `ModelContainer` schema (`Copyd/CopydApp.swift`)
- `Copyd/Utilities/SuggestionRanker.swift`
- `Tests/SuggestionRankerTests.swift`
- the pick funnel: `AppState.paste` / `AutoPaster.finishPick`, plus multi-paste

**Interfaces:**
- `@Model PasteEvent { var clipID: UUID; var appBundleID: String; var at: Date }`
- `enum SuggestionRanker { static func rank(candidates: [Candidate], events: [Event], app: String?, now: Date, limit: Int = 3) -> [UUID] }`, where `Candidate { id, copiedAt, isPinned }` and `Event { clipID, appBundleID, at }` are plain structs.
- Score:

  ```
  3·Σ decay(7 d) over events in this app + 1·Σ decay(7 d) over all events + 0.5·decay(1 d) of copiedAt
  ```

- Ties are broken by `copiedAt`, newest first.
- A clip with no events in this app is only suggested when no clip scores above its recency term.

**Steps:**
- [ ] Write the failing tests first:
  - `testPerAppBeatsGlobal`
  - `testDecayHalvesWeeklyWeight`
  - `testTiesByCopiedAt`
  - `testEmptyHistoryFallsBackToRecency`
  - `testDeletedClipsAreNotSuggested` (events whose clipID is not among the candidates are ignored)
  - `testLimitThree`
- [ ] Implement the ranker and make the tests pass.
- [ ] Record events:
  - Record one `PasteEvent` per clip when a pick actually pastes or copies into another app. Use the app the panel opened over (`PanelController`'s recorded focus app). Multi-paste records one event per joined clip.
  - Trim the log to the last 2,000 events.
  - Delete a clip's events when the clip is deleted.
- [ ] Make sure `PasteEvent` is not part of the iOS, keyboard or widget schemas, and that the sync tracker ignores it. Today the tracker only handles the three synced types; confirm that by reading it.
- [ ] Verify: suite and Mac build.
- [ ] Commit: `[feat] Learn which clips you paste in each app`

### Task 2: Suggested cards in the panel

**Files:**
- the History panel views (`HistoryPanelView`, `CardGridView`, `ClipboardCardView`, `NavigationBarView` filters)
- `Copyd/Utilities/QuickPasteShortcut.swift`
- General settings

**Behavior** (spec §2 UI):
- Up to 3 suggested cards appear first in the History row:
  - Each shows a butter "Suggested" / "Sugerido" chip in place of the type label.
  - A thin divider separates them from the regular cards.
  - A suggested clip is not repeated further down the row.
- Suggestions are hidden when:
  - the search field has text;
  - a pinboard tab is active;
  - a type filter other than All is active;
  - multi-select is active;
  - the setting "Show suggestions" / "Mostrar sugerencias" is off. It is on by default.
- ⌥1–3 pastes suggestion N through the pick funnel. ⌘1–9 counts the displayed cards, suggestions included.
- Compute the ranking once each time the panel opens, from the current candidates (the last 200 non-file clips plus pinned clips) and the app the panel opened over.

**Steps:**
- [ ] Tests:
  - `QuickPasteShortcut` numbering with 3 suggestions in front
  - a test that the row merges suggestions first and removes them from the rest (pure helper `SuggestedRow.merge(suggested:rest:)`)
- [ ] Implement the UI and the ⌥1–3 shortcuts.
- [ ] Verify: suite, Mac build, `check_es`. The orchestrator relaunches the app for a manual check.
- [ ] Commit: `[feat] Show suggested clips first when the panel opens`

### Task 3: Apple Intelligence rerank (macOS 26+)

**Files:**
- `Copyd/Services/SuggestionModel.swift` (`#if canImport(FoundationModels)`, `@available(macOS 26, *)`)
- `Copyd/Utilities/SuggestionPicks.swift` (pure validation)
- `Tests/SuggestionPicksTests.swift`
- General settings

**Behavior** (spec §3, revised):
- Only runs when `SystemLanguageModel.default.availability == .available`.
- Input:
  - the habit top 15, as `{ index, type, preview (≤120 characters, single line) }`;
  - the app's display name and bundle ID;
  - the 5 clips most pasted in that app, with their types.
- Output: `@Generable struct Picks { var indices: [Int] }`.
- Instructions: pick what the user most likely pastes next in this app; prefer content that fits the app; never invent.
- Timeout of 600 ms. The panel shows the habit order immediately, then swaps in the AI order with a crossfade if it arrives in time and passes validation.
- Setting: "Use Apple Intelligence" / "Usar Apple Intelligence", under "Show suggestions". It appears only when the model is available, and it is on by default.

**Steps:**
- [ ] Tests:
  - `SuggestionPicks.validate(indices:count:)` drops out-of-range indices and duplicates, and keeps at most 3, preserving order.
  - `testEmptyAfterValidationFallsBack`
  - a pure `firstWithin(timeout:)` helper tested with a fake async source: it returns nil on timeout.
- [ ] Implement the model session. Create it once and reuse it, with prewarm on panel open.
- [ ] Verify: suite and Mac build. On this Mac (macOS 27), check availability and log a single sample rerank through a DEBUG-only argument; don't launch the app, the orchestrator will. Report whether FoundationModels is available in the SDK.
- [ ] Commit: `[feat] Rerank suggestions with on-device Apple Intelligence`

### Task 4: Mac check with the user, then PR

- [ ] Relaunch the app.
- [ ] Paste the same link 3 times into a browser. On the next panel open in that browser, it should be suggestion 1.
- [ ] With Apple Intelligence on, open the panel in Terminal: the suggestions should lean toward commands.
- [ ] Record the results in `docs/testing/`, update `CLAUDE.md`, push, and open a PR stacked on `feat/paste-power`.
