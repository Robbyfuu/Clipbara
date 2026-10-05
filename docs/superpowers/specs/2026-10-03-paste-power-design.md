# Copyd: Paste Stack, multi-select paste, file sync, and Live Activity

- **Date:** 2026-10-03
- **Status:** Draft, pending the user's approval
- **Branch:** `feat/paste-power`, stacked on `feat/ios-app` (PR #2)
- **Origin:** the user compared Copyd with Pasly and asked for these four features.

## 1. Paste Stack (Mac)

**Goal.** Copy several things in a row, then paste them one after another, in the order you copied them.

**Starting the stack:**
- Menu bar → "Start Paste Stack", or the global shortcut ⌃⌥⌘C. The shortcut can be changed in Settings, like the panel shortcut, through KeyboardShortcuts.
- A small floating HUD at the top center of the screen shows the stack: "Paste Stack · 3". It uses the brand pill style, never takes focus, and can be clicked through.

**While the stack is on:**
- Every new copy is appended to the stack. It still lands in the history as usual.
- The paste key depends on the mode (see the decision below):
  - **(A) Plain ⌘V:** it pastes the next item and removes it from the stack.
  - **(B) Dedicated shortcut, ⌃⌘V:** that shortcut does the same. ⌘V keeps its normal behavior.
- The stack ends when it is empty, when you choose "Stop Paste Stack", or when you press Esc while the HUD is hovered.

**Decision for the user: A or B.**
- **A** works like Pasly. It needs an event tap on ⌘V while the stack is on. Copyd already has Accessibility permission for pasting.
- **B** never touches ⌘V.

**Order.** First in, first out, which is the order you copied. A Settings toggle switches to last in, first out.

**Logic.** `PasteStack` is a pure value type: append, popNext, order and count. It is unit-tested.

## 2. Multi-select and paste with a separator (Mac panel)

**Selecting:**
- ⌘-click toggles one card. ⇧-click selects a range. ⇧→ and ⇧← extend the selection from the keyboard.
- Each selected card shows a butter ring and its selection number.

**The bar.** While two or more cards are selected, a bar appears under the top bar:
- the count: "3 selected";
- a separator picker:
  - New line (the default);
  - Space;
  - Comma (", ");
  - Tab;
  - Custom: a text field, with escapes like `\n`;
- a "Paste" button.

**Pasting:**
- Return pastes all selected text clips joined in selection order. Links paste as their URL text, colors as their hex.
- Images and files can't be joined. If any are selected, the bar says "Text only — 2 skipped" and pastes the rest.
- ⇧Return pastes the joined text as plain text.

**Defaults.** The last separator used is remembered. Esc clears the selection.

**Logic.** `MultiPaste.join(items:separator:)` is pure and unit-tested. It covers order, the skip count, unescaping `\n` and `\t`, and the empty case.

## 3. File sync (Mac ↔ Mac, view and share on iPhone)

**Today.** File clips (`.fileURL`) store only the path and never sync.

**Capture (Mac):**
- When you copy one or more files, the app reads their contents through the pasteboard. The sandbox grants read access to pasteboard file URLs.
- Each file must be ≤ 20 MB, with at most 10 files per clip. Larger copies stay local-only, as today.
- The contents are stored as one bundle per clip: a small manifest (names, sizes, UTIs) plus the file data, in a new `filePayload` field. The bundle is the clip's `rawData` for the new content type `.files`.
- Old `.fileURL` clips keep working unchanged.

**Sync:**
- The bundle is sealed with the existing AES-GCM `AssetCrypto` and uploaded as a `CKAsset`, the same way large images go today.
- Record type `Clip` gains a `fileManifest` field inside `encryptedValues`. CloudKit Development extends the schema by itself. Production deployment stays in the App Store checklist.

**Paste on another Mac:**
- The files are written to `~/Library/Containers/…/Copyd/Files/<clip-id>/`, then put on the pasteboard as file URLs. Pasting works in Finder, Mail and Slack.
- The folder is cleaned up when the clip is deleted.

**iPhone and iPad:**
- A file card shows the icon, the name (or "3 files"), and the total size.
- Tap shares the files through the share sheet, so you can save them to Files or send them.
- The keyboard and the widget skip file clips, as they do today.

**Logic.**
- `FileBundle.encode` / `decode` (manifest + data) are pure and tested: round trip, limits, and filename sanitizing.
- The size gate is also tested.

## 4. Live Activity and push notifications (iPhone)

**Live Activity:**
- Settings has a "Show latest clip on Lock Screen" toggle, off by default. While it is on, Copyd keeps a Live Activity showing the newest clip on the Lock Screen and in the Dynamic Island: a 1–2 line preview, the source, and the age. Images show their thumbnail.
- Tapping it opens `copyd://copy/<id>`, which copies the clip.
- **Updates.** The activity updates when the app applies remote changes, either in the foreground or when a silent CloudKit push wakes it, and after local saves. There is no server, so iOS decides how often the app is woken.
- **Lifetime.** iOS ends activities after 8 hours. The app restarts the activity on its next foreground while the toggle stays on.

**Notifications:**
- Settings has a "Notify me when a clip arrives from another device" toggle, off by default. Turning it on asks for notification permission.
- When the sync engine applies new remote clips while the app is in the background, it posts one local notification:
  - title: "New clip from your Mac", or "N new clips";
  - body: the preview, cut to 80 characters. Private copies are already never captured.
  - Tapping the notification opens History.
- Clips that iOS's own Universal Clipboard brought in are not announced. Only remote inserts are.

**Logic.** `ArrivalNotice.text(for:)` builds the title and body. It is pure and tested, including plurals and truncation, in English and Spanish.

## 5. Out of scope

- Field Sense.
- Floating Paste.
- Hijacking ⌘V outside Paste Stack.
- Streaming large files.
- Syncing folders.
- Live Activity push updates through APNs, which need a server.

## 6. Testing

- **Unit tests:** `PasteStack`, `MultiPaste`, `FileBundle`, `ArrivalNotice`, plus the file-limit gate.
- **Mac, by hand:**
  - Paste Stack order.
  - Multi-select join with each separator.
  - Copy 3 files on Mac A, then paste them in Finder on Mac B. This joins the pending two-Mac check.
- **iPhone:**
  - The file card shares the files.
  - The Live Activity appears and updates when you copy on the Mac.
  - A notification arrives with the app in the background.
- **Spanish:** every new string has `es`, and `check_es` reports 0 missing.
