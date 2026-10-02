# History Panel Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restyle the bottom history panel in the Copyd brand, make it span the full screen width, improve card previews, and add ⌘1–9 quick paste of visible cards.

**Architecture:** The pure units (`QuickPasteShortcut`, `PanelGeometry`, `PinboardDot`) carry all logic that can be unit-tested. The SwiftUI views get restyled against new brand tokens in `DesignTokens`. `PanelController` gets a full-width frame and a `flagsChanged` monitor. `AppState` gains two observable fields that the grids and cards read.

**Tech Stack:** Swift 6 (strict concurrency complete), SwiftUI + AppKit (`NSPanel`), SwiftData, XCTest, XcodeGen. macOS 14.

**Spec:** `docs/superpowers/specs/2026-10-02-panel-redesign-design.md`. The visual reference is the "Mac · history panel v2" artboard in https://claude.ai/artifact/JL8YPe6HYLXk697JJznCpd.

## Global Constraints

- macOS 14 deployment target. Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`. No new SPM dependencies, no bundled fonts (use the system font).
- Both targets (`Clipbara`, `ClipbaraMAS`) get the redesign. Only the sync chip is behind `#if CLOUDSYNC`.
- Colors come only from `DesignTokens` tokens, never from inline literals in views. Brand values (light / dark): shelf `#F2F0E9`/`#12121A`, card `#FEFDFB`/`#1E1E29`, line `#D8D8E0`/`#32323D`, ink `#191926`/`#F3F2ED`, ink2 `#575763`/`#A9AAB4`, chip `#E4E1D9`/`#2A2A35`, butter `#F8D14F` (both), onButter `#191926` (both).
- Radii: panel top 20, card 16, preview well 10, search 10, pills capsule. Panel height 300. Cards 200 × 220, 12 apart, 16 strip padding.
- Shortcuts: ⌘1–9 paste the Nth visible card, ⇧⌘1–9 paste it as plain text, ⌥⌘1–9 switch tabs. Number row and keypad both work.
- Every SwiftData mutation is followed by `try? modelContext.save()` (UI code).
- Before every paste, call `ClipboardMonitor.skipNextChange()`.
- No `@Query` view may be shown or hidden with `if`/`else` inside `NSHostingView`; use the ZStack + opacity pattern (CLAUDE.md).
- Keep `VisualEffectBackground.swift` and every other existing file. This plan deletes no files.
- Commits use the format `[type] what and why`, with no `Co-Authored-By` line. Use `/usr/bin/git`; the plain `git` wrapper is blocked in this worktree.
- Prefix every `xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and pass `-derivedDataPath DerivedData`.
  - Tests: `xcodebuild test -project Clipbara.xcodeproj -scheme ClipbaraTests -destination 'platform=macOS' -derivedDataPath DerivedData`. The baseline is 129 tests passing.
  - Builds: `-scheme Clipbara -configuration Debug build` and `-scheme ClipbaraMAS -configuration Debug -allowProvisioningUpdates build`. Run `xcodegen generate` after editing `project.yml`.
- Do not launch the app in Tasks 1–6. Task 7 launches it for the user.

## Review Focus

1. With the search field focused, ⌘3 must paste the third visible card. It must not type "3" into the search. Task 6 handles the shortcut before the text-field pass-through and checks this manually.
2. After scrolling, switching tabs, or typing a search, ⌘1 must target the leftmost card currently visible, never a stale one. Task 6 resets `firstVisibleIndex` to 0 on tab, search, and filter changes, and checks this manually.
3. On a second display with a negative origin, the panel must cover that display's full width. Pinned by `PanelGeometryTests.testSecondaryScreenWithNegativeOrigin` (Task 3).
4. If ⌘ is held while the panel hides, the number badges must not still be showing on the next open. Task 6 resets `isCommandHeld` in `hidePanel` and checks this manually.
5. A number with no card behind it (only 2 cards, user presses ⌘5) must do nothing and must not reach the frontmost app. Pinned by `QuickPasteShortcutTests.testNumberPastEndIsNil` (Task 1), plus the monitor consuming the event (Task 6).

---

## File Map

| File | Status | Responsibility |
|---|---|---|
| `Clipbara/Utilities/QuickPasteShortcut.swift` | Create | Number-key matching shared by paste and tabs; number → item index |
| `Clipbara/Utilities/PanelTabShortcut.swift` | Modify | Tabs move to ⌥⌘; reuse `NumberKey` |
| `Clipbara/Utilities/PanelGeometry.swift` | Create | Full-width, bottom-aligned panel frame |
| `Clipbara/Utilities/PinboardDot.swift` | Create | Stable palette index per pinboard id |
| `Clipbara/Utilities/DesignTokens.swift` | Modify | Brand color tokens, pinboard dot palette, new sizes |
| `Clipbara/Views/CopydMark.swift` | Create | The Copyd mark as a SwiftUI view |
| `Clipbara/Panel/PanelController.swift` | Modify | Geometry, no content-count resizing, `flagsChanged` monitor, quick-paste key handling |
| `Clipbara/Views/HistoryPanelView.swift` | Modify | Shelf background with top-rounded shape and top border |
| `Clipbara/Views/NavigationBarView.swift` | Modify | New top bar order and style, ⌘F, sync chip |
| `Clipbara/Views/ClipboardCardView.swift`, `Clipbara/Views/CardContent/*.swift` | Modify | Card layout, previews per type, selection ring, number badge |
| `Clipbara/Views/CardGridView.swift`, `Clipbara/Views/PinboardGridView.swift` | Modify | Card size and spacing, report first visible index |
| `Clipbara/AppState.swift` | Modify | `firstVisibleIndex`, `isCommandHeld`, `quickPaste(number:plainText:)` |
| `Tests/QuickPasteShortcutTests.swift`, `Tests/PanelGeometryTests.swift`, `Tests/PinboardDotTests.swift`, `Tests/PanelTabShortcutTests.swift` | Create / Modify | Unit tests |
| `project.yml` | Modify | Add the new pure files to `ClipbaraTests` sources |

---

### Task 1: Quick-paste shortcut and tab shortcut move

**Files:**
- Create: `Clipbara/Utilities/QuickPasteShortcut.swift`
- Modify: `Clipbara/Utilities/PanelTabShortcut.swift`
- Modify: `project.yml` (add `QuickPasteShortcut.swift` to `ClipbaraTests` sources)
- Test: `Tests/QuickPasteShortcutTests.swift` (create), `Tests/PanelTabShortcutTests.swift` (modify)

**Interfaces:**
- Produces:
  ```swift
  enum NumberKey { static func index(keyCode: UInt16) -> Int? }   // 0...8 for "1"..."9" on number row (18,19,20,21,23,22,26,28,25) and keypad (83...92 minus 90)
  enum QuickPasteShortcut {
      struct Match: Equatable { let number: Int; let plainText: Bool }   // number 0...8
      static func match(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Match?   // [.command] → plainText false; [.command, .shift] → true; anything else → nil
      static func itemIndex(number: Int, firstVisibleIndex: Int, itemCount: Int) -> Int?   // firstVisibleIndex + number if < itemCount, else nil; nil for number outside 0...8
      static func hint(number: Int) -> String?   // "⌘1"..."⌘9"
  }
  ```
  `PanelTabShortcut.index` now requires exactly `[.command, .option]` and calls `NumberKey.index`. `PanelTabShortcut.hint(at:)` returns `"⌥⌘\(index + 1)"`.

- [ ] **Step 1: Write the failing tests.**
  - `QuickPasteShortcutTests`:
    - `testCommandDigitsMapToNumbers`: keyCode 18 gives `Match(number: 0, plainText: false)`, and keyCode 25 gives number 8.
    - `testKeypadMatchesNumberRow`
    - `testShiftCommandIsPlainText`
    - `testOtherChordsAreNotQuickPaste`: `[]`, `.option`, `[.command, .option]`, `[.command, .control]` and `[.command, .shift, .option]` all return nil.
    - `testCapsLockIsIgnored`: `[.command, .capsLock]` matches.
    - `testZeroIsNotAShortcut`: keyCode 29 returns nil.
    - `testItemIndexOffsetsByFirstVisible`: `(2, 12, 30)` gives 14.
    - `testNumberPastEndIsNil`: `(3, 0, 3)` gives nil.
    - `testOutOfRangeNumberIsNil`: `-1` and `9` give nil.
    - `testHints`: "⌘1" … "⌘9", and nil outside that range.
  - Update `PanelTabShortcutTests`:
    - `testNumberRowMapsToVisibleTabOrder` and `testKeypadMapsToTheSameTabs` use `[.command, .option]`.
    - `testRequiresCommandAndOption` replaces `testRequiresCommand`. It asserts nil for `[]`, `.command`, `.option`, `[.command, .shift]` and `.control`.
    - `testRejectsExtraChordModifiers` adds `.shift` / `.control` on top of `[.command, .option]`.
    - `testCapsLockDoesNotDisableShortcut` uses `[.command, .option, .capsLock]`.
    - `testHintsMatchShortcutRange` expects "⌥⌘\(index + 1)".
- [ ] **Step 2: Run the tests.** Expected: compile failure for `QuickPasteShortcut`, and failures in the updated `PanelTabShortcutTests`.
- [ ] **Step 3: Implement** `NumberKey` and `QuickPasteShortcut` in the new file. Make `PanelTabShortcut` use `NumberKey` and the ⌥⌘ chord. Compare `modifiers.intersection([.command, .option, .control, .shift])` exactly, as the existing code does.
- [ ] **Step 4: Run the full suite.** Expected: every test passes.
- [ ] **Step 5: Commit** `[feat] Add quick-paste number shortcuts and move tab switching to Option-Command`.

---

### Task 2: Brand tokens, pinboard dots, and the Copyd mark

**Files:**
- Create: `Clipbara/Utilities/PinboardDot.swift`, `Clipbara/Views/CopydMark.swift`
- Modify: `Clipbara/Utilities/DesignTokens.swift`
- Modify: `project.yml` (add `PinboardDot.swift` to `ClipbaraTests`)
- Test: `Tests/PinboardDotTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PinboardDot { static let paletteCount = 6; static func index(for id: UUID) -> Int }   // sum of the 16 uuid bytes % 6 — never hashValue (randomized per launch)
  extension DesignTokens {
      enum Brand {   // dynamic: resolve light/dark via NSColor(name:dynamicProvider:) checking appearance.bestMatch(from: [.darkAqua, .aqua])
          static let shelf, card, line, ink, ink2, chip, butter, onButter: Color
      }
      static let pinboardDots: [Color]   // #4C9DEB, #4EB068, #E17363, #AD80DD, #00B1BA, #CE871B (same in both modes)
  }
  struct CopydMark: View { var size: CGFloat }   // butter rounded card with counter hole + ink stem; geometry from the 64-unit artboard: card rect (6,20,40,40) r14 with circle hole center (19,40) r7 (even-odd fill), stem rect (32,4,14,56) r7; drawn in a 64×64 space offset -6 on x so it is centered
  ```
  The Card / Header / Body / Badge / Selection / Nav tokens are replaced with the spec §4/§6/§7 values. `typeTint` stays for `.color` only; every other type returns `Brand.ink2`. The `Checkerboard` token is deleted once Task 5 no longer uses it. Leave it in this task.

- [ ] **Step 1: Write the failing tests.**
  - `PinboardDotTests.testSameIDSameIndex`
  - `testKnownID`: `UUID(uuidString: "00000000-0000-0000-0000-000000000007")!` gives index 1.
  - `testIndexInRange`: 200 random UUIDs all land in `0..<6`.
- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement** `PinboardDot`, the `Brand` tokens, `pinboardDots`, and `CopydMark`. Draw `CopydMark` with `Path` and `.fill(style: FillStyle(eoFill: true))` for the card, so the hole is real transparency.
- [ ] **Step 4: Run the full suite and build both targets.** Expected: all tests pass and both builds succeed. Existing views still compile, because old token names that they use either remain or map to the new values.
- [ ] **Step 5: Commit** `[feat] Add Copyd brand tokens, pinboard dot palette and the Copyd mark`.

---

### Task 3: Full-width panel geometry and shelf background

**Files:**
- Create: `Clipbara/Utilities/PanelGeometry.swift`
- Modify:
  - `Clipbara/Panel/PanelController.swift`: lines 27–33 (constants), `prewarm`, `showPanel`, `resizeToContentItemCount` (lines 162–193), `panelFrame` and `targetPanelWidth` (lines 644–668)
  - `Clipbara/Views/CardGridView.swift:110` and `Clipbara/Views/PinboardGridView.swift:128`: remove the `resizeToContentItemCount` calls
  - `Clipbara/Views/HistoryPanelView.swift`
  - `project.yml`
- Test: `Tests/PanelGeometryTests.swift`

**Interfaces:**
- Consumes: `DesignTokens.Brand.shelf`, `DesignTokens.Brand.line` (Task 2).
- Produces: `enum PanelGeometry { static let height: CGFloat = 300; static func frame(visibleFrame: NSRect, height: CGFloat) -> NSRect }`. The frame uses `x = visibleFrame.minX`, `y = visibleFrame.minY`, `width = visibleFrame.width`, and `height = min(height, visibleFrame.height)`.

- [ ] **Step 1: Write the failing tests.**
  - `testFullWidthBottomAligned`: `(0, 25, 1512, 920)` with h 300 gives `(0, 25, 1512, 300)`.
  - `testSecondaryScreenWithNegativeOrigin`: `(-1920, 0, 1920, 1055)` gives `(-1920, 0, 1920, 300)`.
  - `testHeightNeverExceedsVisibleHeight`: visible height 250 gives height 250.
- [ ] **Step 2: Run the tests.** Expected: compile failure.
- [ ] **Step 3: Implement `PanelGeometry`.**
  - Replace `panelFrame(in:itemCount:y:)` with a call to it, keeping the existing `y` parameter for the slide animation, and use `PanelGeometry.height` for `baseHeight`.
  - Delete `targetPanelWidth`, `resizeToContentItemCount`, and the width constants. Remove the two call sites.
  - In `HistoryPanelView`, replace `VisualEffectBackground` with `UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20).fill(DesignTokens.Brand.shelf)`, plus a 1 pt `Brand.line` stroke on the top edge only. A top-aligned `Rectangle` of height 1, masked by the same shape, is acceptable.
- [ ] **Step 4: Run the full suite and build both targets.** Expected: all tests pass, and no references to the deleted functions remain (`/usr/bin/grep -rn resizeToContentItemCount Clipbara` prints nothing).
- [ ] **Step 5: Commit** `[feat] Span the history panel across the full screen width with the brand shelf`.

---

### Task 4: Top bar

**Files:**
- Modify: `Clipbara/Views/NavigationBarView.swift`. The `navigationBar` (lines 85–102), `tabGroup`, `actionGroup`, `searchField`, `NavTabButton`, and `NavIconButton` change.

**Interfaces:**
- Consumes:
  - `CopydMark` (Task 2)
  - `DesignTokens.Brand.*` and `DesignTokens.pinboardDots` (Task 2)
  - `PinboardDot.index(for:)` (Task 2)
  - `PanelTabShortcut.hint(at:)` (Task 1, now "⌥⌘N")
  - `#if CLOUDSYNC` `appState.cloudSync?.status` (`CloudSyncEngine.Status`)

- [ ] **Step 1: Reorder and restyle per spec §6.**
  - Order, left to right: `CopydMark(size: 24)`, the tab pills with "+", a flexible search field centered in the remaining space (max width 420, height 34, `Brand.chip` fill, trailing "⌘F" hint), the sync chip, "…", and trash.
  - Tab pills: 32 pt capsules. Active tabs get a `Brand.butter` fill with `Brand.onButter` text. Inactive tabs show `Brand.ink2` text and, for pinboards, an 8 pt dot from `DesignTokens.pinboardDots[PinboardDot.index(for: pinboard.id)]`. The `folder` and `clock` icons are removed from the pills.
  - Tooltips use `PanelTabShortcut.hint`. History becomes "History (⌥⌘1)".
  - All existing behaviors stay intact: drop targets, rename, delete, the add-pinboard sheet, and the clear-history alert.
- [ ] **Step 2: ⌘F.** If nothing already focuses the search field on ⌘F, add `.keyboardShortcut("f", modifiers: .command)` to a hidden button that sets `isSearchFocused = true`. Do not add it to the key monitor.
- [ ] **Step 3: Sync chip (`#if CLOUDSYNC`).** Show it only when `appState.cloudSync` exists and the status is not `.off`.
  - Text, mapped from the status:
    - `.upToDate(date)` → "Synced · now" when the date is under 60 s old, otherwise "Synced · \(minutes) min".
    - `.syncing` → "Syncing…".
    - Any other case → "Sync paused".
  - Style: a lock SF Symbol (`lock.fill`, 11 pt), 12 pt semibold text, a `Brand.chip` capsule, and 28 pt height.
  - Action: open Settings with the `openSettings` environment action.
- [ ] **Step 4: Build both targets and run the full suite.** Expected: both builds succeed and all tests pass. The DMG build has no sync chip (the `#if` excludes it).
- [ ] **Step 5: Commit** `[feat] Restyle the panel top bar with the Copyd mark, pill tabs and a sync chip`.

---

### Task 5: Cards

**Files:**
- Modify: `Clipbara/Views/ClipboardCardView.swift`, `Clipbara/Views/CardContent/{Text,Image,Link,Color,File}CardContent.swift`, `Clipbara/Views/CardGridView.swift` (size, spacing, padding), `Clipbara/Views/PinboardGridView.swift` (same)
- Modify: `Clipbara/Utilities/DesignTokens.swift`. Delete `Checkerboard` once it is unused.

**Interfaces:**
- Consumes: `DesignTokens.Brand.*` and `typeTint` (Task 2).
- Produces:
  - `ClipboardCardView` gains `var quickPasteNumber: Int? = nil` (0…8). When it is non-nil and `appState.isCommandHeld` is true, the card shows the badge.
  - This task also declares the two `AppState` properties the badge needs: `var firstVisibleIndex: Int = 0` and `var isCommandHeld: Bool = false`. Task 6 sets them.

- [ ] **Step 1: Card shell per spec §7.**
  - Size: 200 × 220, padding 10, `Brand.card` fill, 1 pt `Brand.line` border, radius 16.
  - Header: 11 pt semibold `ink2`, with the type SF Symbol and label, a spacer, the relative time, and the source app icon at 16 pt with radius 4.
  - Footer: 11 pt `ink2`, with type-specific text and the existing "…" menu button at the trailing end.
    - Images: "W × H · size".
    - Text and HTML: "N chars".
    - Links: source app name.
    - Color: hex value in `.monospaced()`.
    - File: "Stays on this Mac" under `#if CLOUDSYNC`, otherwise the file size.
  - Selected state: a 1 pt `butter` border plus a 3 pt `butter` outer ring (`.overlay` stroke, then a `.padding(-3)` stroked shape). This replaces `Selection.borderColor` blue.
  - Hover lift: keep it as it is.
- [ ] **Step 2: Previews per type.** Each preview sits in a well with radius 10.
  - Image: `.aspectRatio(contentMode: .fill)`, clipped, on a `Brand.chip` fill. Remove `CheckerboardPattern`.
  - Text and HTML: 13 pt `ink`, no line limit inside the well. Add a bottom fade with `.mask(LinearGradient(stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))`, applied only when the text overflows. Applying it always is acceptable; keep it simple.
  - Link: `Brand.chip` well, with the domain in 17 pt bold `ink` and the path below it in 11 pt monospaced `ink2`, bottom-aligned.
  - Color: the whole well filled with the clip's color.
  - File: `Brand.chip` well, with the file icon at 36 pt and its name in 13 pt semibold, centered.
- [ ] **Step 3: Grids.** `CardGridView` and `PinboardGridView` use the fixed 200 × 220 size, spacing 12, and 16 horizontal padding. Remove the `GeometryReader` size math.
- [ ] **Step 4: Number badge rendering.** When `quickPasteNumber != nil && appState.isCommandHeld`, overlay a badge at top-leading, offset (-6, -6): `butter` capsule, `onButter` text "⌘N" (from `QuickPasteShortcut.hint`), 11 pt semibold, `.accessibilityHidden(true)`.
  - The card's `.accessibilityLabel` reads "\(type), \(summary), from \(app)". When numbered, it appends ", Command \(n + 1) to paste".
- [ ] **Step 5: Build both targets and run the full suite.** Expected: both builds succeed and all tests pass, and `/usr/bin/grep -rn Checkerboard Clipbara` prints nothing.
- [ ] **Step 6: Commit** `[feat] Restyle clip cards with full-bleed previews and the butter selection ring`.

---

### Task 6: Quick paste wiring

**Files:**
- Modify: `Clipbara/AppState.swift`, `Clipbara/Panel/PanelController.swift` (`installKeyMonitor`, lines 389–441, a new `flagsChanged` monitor next to it, removal in the existing monitor teardown around line 594, and `hidePanel`), `Clipbara/Views/CardGridView.swift`, `Clipbara/Views/PinboardGridView.swift`

**Interfaces:**
- Consumes:
  - `QuickPasteShortcut.match` and `itemIndex` (Task 1)
  - `ClipboardCardView.quickPasteNumber` (Task 5)
  - `appState.currentFilteredItems`, already set by both grids
- Produces:
  - On `AppState`: `func quickPaste(number: Int, plainText: Bool)`. The `firstVisibleIndex` and `isCommandHeld` properties already exist from Task 5.
  - `quickPaste` resolves `QuickPasteShortcut.itemIndex(number:firstVisibleIndex:itemCount: currentFilteredItems.count)`, then calls `paste(item, asPlainText: plainText ? true : nil)` (which already calls `skipNextChange`) and `hidePanel()`. If no item resolves, it does nothing.

- [ ] **Step 1: Key monitor.** In `installKeyMonitor`, before the existing tab-shortcut check, add:

  ```swift
  if let match = QuickPasteShortcut.match(keyCode: keyCode, modifiers: event.modifierFlags) {
      self.appState?.quickPaste(number: match.number, plainText: match.plainText)
      return true
  }
  ```

  The check must run before the text-field pass-through, so it also works while search is focused.
- [ ] **Step 2: `flagsChanged` monitor.**
  - Install it alongside the key monitor. It sets `appState.isCommandHeld = event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command`, only while the panel is visible.
  - Remove it in the same teardown as the key monitor.
  - In `hidePanel`, set `isCommandHeld = false` and `firstVisibleIndex = 0`.
- [ ] **Step 3: First visible index.** In both grids:
  - Add `.scrollTargetLayout()` to the `LazyHGrid`, and `.scrollPosition(id: $leadingID)` to the `ScrollView`. Use `@State private var leadingID: UUID?`, the item or entry ids.
  - On `leadingID` change, set `appState.firstVisibleIndex` to that id's index in the grid's items, or 0 if it is not found.
  - Reset `firstVisibleIndex = 0` when items are re-filtered: on tab change, search change, and filter change, inside the existing `updateFilteredItems`.
  - Pass `quickPasteNumber: (index - appState.firstVisibleIndex)` to each card when that value is in `0...8`, otherwise nil.
- [ ] **Step 4: Build both targets and run the full suite.** Expected: both builds succeed and all tests pass.
- [ ] **Step 5: Commit** `[feat] Paste the Nth visible clip with Command-number and show number hints while Command is held`.

---

### Task 7: Visual and behavior check with the user

**Files:** none, unless a defect is found. Each defect is fixed in the owning task's files and committed as `[fix] …`.

- [ ] **Step 1: Prepare the app.** Build `ClipbaraMAS` last and launch it with `open -n "$PWD/DerivedData/Build/Products/Debug/Copyd.app" --args -ClipbaraDebugOriginalAppVersion 1.0`. Kill any earlier instance by its full path first.
- [ ] **Step 2: The user runs the checks from spec §10 and Review Focus 1, 2 and 4.** The orchestrator lists them one at a time:
  - light and dark mode
  - the panel's width on this screen
  - each card type
  - holding ⌘ to show the numbers
  - ⌘3 with the search field focused
  - ⌘1 after scrolling
  - ⌥⌘2 to switch to the first pinboard
- [ ] **Step 3: Record the results.** Add a short "Panel redesign" section to `docs/testing/icloud-sync.md`, or to a new `docs/testing/panel-redesign.md`, and commit `[docs] Record panel redesign check`.
