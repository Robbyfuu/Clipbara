# Copyd: Smart Suggestions (what you'll paste next)

- **Date:** 2026-10-04
- **Status:** approved in direction by the user ("Las dos, por etapas"); details below
- **Branch:** `feat/paste-power`, after the current Paste Power tasks
- **Origin:** the user shared Paste 7's "Smart Clipboard" and asked for an equivalent.

## 1. Goal

When the panel opens, show at the top the 3 clips the user is most likely to paste into the app and field they're in now, so the right item is already there.

## 2. Stage 1 — Suggestions from habit (macOS 14+, no AI)

### Learning
- Every pick that pastes (the auto-paste funnel and multi-paste) records one `PasteEvent`: `{ clipID, appBundleID, fieldKind?, at }`.
- Storage: a small SwiftData model `PasteEvent`, local only and never synced.
  - The table is trimmed to the last 2,000 events.
  - Events that point at deleted clips are removed with the clip.
- `appBundleID` is the frontmost app when the panel opened. `PanelController` already captures the previous app for focus restore; reuse it.

### Ranking
`SuggestionRanker.rank(candidates:events:app:now:) -> [UUID]` is a pure function. It returns the top 3 of:

```
score = 3.0·pastedInThisApp(decayed, half-life 7 d) + 1.0·pastedAnywhere(decayed) + 0.5·recency(copiedAt, half-life 1 d) + 2.0·kindMatch(fieldKind, clip type)
```

- `kindMatch` applies only when `fieldKind` is known (stage 2).
- Ties are broken by `copiedAt` descending.
- Clips with zero app history are only suggested when nothing else scores above recency.
- **Candidates:** the last 200 non-file clips, plus pinned clips. Never `rawData`.

### UI (panel)
- A "Suggested for Mail" / "Sugeridos para Mail" row of up to 3 compact cards, above the normal card row.
  - Use the app's display name.
  - The row is hidden when there are no suggestions, the search field has text, or a pinboard tab is selected.
- **Keyboard:** suggestions take ⌥1–3 ("⌥1 pega la sugerencia 1") and paste like any pick. ⌥⌘ stays the tab switch.
- **Setting:** "Show suggestions" / "Mostrar sugerencias", in General, on by default.

## 3. Stage 2 — Apple Intelligence rerank (macOS 26+, Apple Intelligence on)

### Field context
When the panel opens, use the Accessibility permission the user already grants for direct paste to read the focused UI element of the previous app:
- `AXFocusedUIElement`
- its `AXRole`, `AXTitle` / `AXDescription` / `AXPlaceholderValue`
- the window title (`AXTitle` of `AXFocusedWindow`)

`FieldContext.classify` maps these to a `fieldKind`:

| fieldKind | Signals |
|---|---|
| `email` | address-like fields ("To", "Para", "Email") |
| `url` | the address bar |
| `terminal` | a Terminal/iTerm/Ghostty window |
| `code` | an editor |
| `address` | "Address", "Dirección" |
| `phone` | phone fields |
| `search` | search fields |
| `plain` | anything else |

- This is a pure function over strings, with no model involved.
- Without the Accessibility permission, `fieldKind` is nil and stage 1 runs alone.

### Rerank
- Only when `SystemLanguageModel.default.availability == .available`, using the Foundation Models framework.
- Send the stage-1 top 15 candidates. Each is sent as `{ index, type, preview (first 120 chars, single line) }`, plus the app name, `fieldKind` and field label.
- Use a `@Generable` struct `Picks { var indices: [Int] }`, limited to 3.
- The session instructions say: choose what the user most likely pastes next in this field; prefer exact type matches; never invent.
- **Fallbacks:**
  - Timeout 600 ms. On timeout, error, or invalid indices, show stage 1 unchanged.
  - The panel never waits: it shows stage 1 at once and swaps in the AI order when it arrives, with a subtle crossfade.
- **Privacy:** fully on-device, through the Apple Intelligence on-device model. No network. Previews are cut to 120 characters, and clips from concealed or excluded apps are never captured in the first place.
- **Setting:** "Use Apple Intelligence" / "Usar Apple Intelligence", sub-option of Show suggestions. It is shown only when the model is available, and it is on by default.

## 4. Testing

- Unit tests:
  - `SuggestionRanker`: per-app beats global, decay, ties, kind match, empty history.
  - `FieldContext.classify`: each kind, in English and Spanish labels.
  - Response parsing for `Picks` validation: out-of-range indices, duplicates, more than 3.
- Mac, by hand:
  - Paste the same link into Mail 3 times; it shows as suggestion 1 when the panel opens in Mail.
  - With Apple Intelligence on, in Mail's "To" field, an email clip ranks first.

## 5. Out of scope

- Suggestions on iPhone and iPad (keyboard). This could be a later step, using the same ranker with the host app unknown.
- Syncing the paste history across devices.
- Learning from the content of what is typed.
