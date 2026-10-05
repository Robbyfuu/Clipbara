# Copyd: Smart Suggestions (what you'll paste next)

- **Date:** 2026-10-04
- **Status:** approved in direction by the user ("Las dos, por etapas"); details below
- **Branch:** `feat/paste-power`, after the current Paste Power tasks
- **Origin:** the user shared Paste 7's "Smart Clipboard" and asked for an equivalent.

## 1. Goal

When the panel opens, show at the top the 3 clips the user is most likely to paste into the app and field they're in now, so the right item is already there.

## 2. Stage 1 — Suggestions from habit (macOS 14+, no AI)

### Learning
- Every pick that pastes (the auto-paste funnel and multi-paste) records one `PasteEvent`: `{ clipID, appBundleID, at }`.
- Storage: a small SwiftData model `PasteEvent`, local only and never synced.
  - The table is trimmed to the last 2,000 events.
  - Events that point at deleted clips are removed with the clip.
- `appBundleID` is the frontmost app when the panel opened. `PanelController` already captures the previous app for focus restore; reuse it.

### Ranking
`SuggestionRanker.rank(candidates:events:app:now:) -> [UUID]` is a pure function. It returns the top 3 of:

```
score = 3.0·pastedInThisApp(decayed, half-life 7 d) + 1.0·pastedAnywhere(decayed) + 0.5·recency(copiedAt, half-life 1 d)
```

- Ties are broken by `copiedAt` descending.
- Clips with zero app history are only suggested when nothing else scores above recency.
- **Candidates:** the last 200 non-file clips, plus pinned clips. Never `rawData`.

### UI (panel)
- **No separate row.** The panel has about 8 pt of spare height, so suggestions don't get a row of their own (ruling 2026-10-04). Instead, up to 3 suggested clips are shown first in the History row:
  - They are marked with a small butter "Suggested" / "Sugerido" chip in place of the type label.
  - A thin divider separates them from the normal, chronological cards.
  - A suggested clip is not repeated further down the row.
- **When suggestions are hidden:**
  - the search field has text;
  - a pinboard tab is selected;
  - a type filter other than "All" is active;
  - multi-select is active.
- **Keyboard.** Suggestions take ⌥1–3 ("⌥1 pega la sugerencia 1") and paste like any other pick. ⌥⌘ stays the tab switch. ⌘1–9 keeps counting the visible cards, suggestions included, exactly as displayed.
- **Setting.** "Show suggestions" / "Mostrar sugerencias", in General, on by default.

## 3. Stage 2 — Apple Intelligence rerank by app (macOS 26+, Apple Intelligence on)

**Revised 2026-10-04.** The first version of this stage read the focused field (`AXFocusedUIElement`, its labels, the window title). Review confirmed that `AXUIElement` APIs do not work in the App Sandbox, and the window title needs Screen Recording. The user chose to keep stage 2 with app context only.

- **Context.** The model gets only what Copyd already knows:
  - the previous app's display name and bundle id (Mail, Terminal, Safari…);
  - the stage-1 history for that app: the 5 clips most pasted there, with their types.

  There is no field label and no window title.
- **Rerank.**
  - Runs only when `SystemLanguageModel.default.availability == .available` (Foundation Models).
  - Sends the stage-1 top 15 candidates. Each is sent as `{ index, type, preview (first 120 chars, single line) }`, plus the app context above.
  - Uses a `@Generable` struct `Picks { var indices: [Int] }`, at most 3.
  - Instructions: pick what the user most likely pastes next in this app, using the app's purpose and the paste history; prefer content that fits the app (for example commands in a terminal, links in a browser, addresses and emails in Mail); never invent.
- **Fallbacks.**
  - Timeout of 600 ms. On timeout, an error, or invalid indices, keep the stage-1 order.
  - The panel never waits. It shows stage 1 right away and swaps in the AI order when it arrives, with a crossfade.
- **Privacy.** The model runs on device. There is no network. Previews are capped at 120 characters.
- **Setting.** "Use Apple Intelligence" / "Usar Apple Intelligence", under "Show suggestions". Shown only when the model is available; on by default.

## 4. Testing

- Unit tests:
  - `SuggestionRanker`: per-app beats global, decay, ties, empty history.
    - Response parsing for `Picks` validation: out-of-range indices, duplicates, more than 3.
- Mac, by hand:
  - Paste the same link into Mail 3 times; it shows as suggestion 1 when the panel opens in Mail.
  - With Apple Intelligence on, in Terminal, a command-like clip ranks above a link.

## 5. Out of scope

- Suggestions on iPhone and iPad (keyboard). This could be a later step, using the same ranker with the host app unknown.
- Syncing the paste history across devices.
- Learning from the content of what is typed.
