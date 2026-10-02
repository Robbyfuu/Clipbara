# History panel redesign and ⌘-number quick paste

- Date: 2026-10-02
- Status: Draft, pending review
- Branch: `feat/panel-redesign`, stacked on `feat/icloud-sync` (it uses the sync status and the Copyd naming)
- Visual reference: artboard "Mac · history panel v2 (full-width shelf)" in the Copyd brand canvas (https://claude.ai/artifact/JL8YPe6HYLXk697JJznCpd). The user approved its direction on 2026-10-02.

## 1. Goals

1. The history panel looks like Copyd: brand colors, the Copyd mark, and the butter selection ring, in both light and dark mode.
2. The panel spans the full width of the screen it opens on, flush with the bottom of the visible area.
3. Card previews show their content instead of chrome: an image fills its card, text gets more lines, and links lead with the domain.
4. The top bar has a clear order: boards, then search, then status and actions.
5. ⌘1–⌘9 paste the visible cards directly, without selecting them first.

## 2. Non-goals

- Rendering HTML markup. HTML clips show their plain text, styled like text clips. The table in the mockup is not part of this cut.
- Bundling brand fonts. The panel uses the system font (SF Pro).
- Changes to the Quick Look preview window, Settings, onboarding or the menu-bar menu.
- New card actions. The existing context menu and the "…" menu keep their items.

## 3. Scope

The redesign applies to both targets, `Clipbara` (DMG) and `ClipbaraMAS` (Copyd). The only target-specific element is the sync status chip, which exists only under `#if CLOUDSYNC`. Both builds show the Copyd mark, because the fork is becoming Copyd. Accepted cost: merges from upstream will conflict in these view files.

## 4. Tokens (`Clipbara/Utilities/DesignTokens.swift`)

The current colors are replaced by these values (sRGB, converted from the brand OKLCH values):

| Token | Light | Dark |
|---|---|---|
| `shelf` (panel background) | `#F2F0E9` | `#12121A` |
| `card` | `#FEFDFB` | `#1E1E29` |
| `line` (borders) | `#D8D8E0` | `#32323D` |
| `ink` (primary text) | `#191926` | `#F3F2ED` |
| `ink2` (secondary text) | `#575763` | `#A9AAB4` |
| `chip` (search field, preview wells, badges) | `#E4E1D9` | `#2A2A35` |
| `butter` (accent: active tab, selection ring, number hints) | `#F8D14F` | `#F8D14F` |
| `onButter` (text on butter) | `#191926` | `#191926` |

- Each token is a `Color` that resolves per appearance. Use `NSColor(name:dynamicProvider:)` bridged to `Color` so it follows the app's System/Light/Dark setting.
- The per-type accent tints (`typeTint`) stay only for color clips, which show their own color. Every other type uses `ink2` for its icon.
- Radii: panel top corners 20, card 16, preview well 10, search field 10, pills fully rounded.

## 5. Panel geometry (`PanelController`)

- **Width** is the full width of the active screen's `visibleFrame`. The panel stops resizing to the number of items, so `resizeToContentItemCount` and `targetPanelWidth` go away.
- **Height** is 300 pt. The bottom edge sits at `visibleFrame.minY`, which keeps it above a bottom Dock.
- **Shape**: only the top corners are rounded, by drawing the background with `UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)`. The window stays transparent, and a 1 pt `line` border runs along the top edge.
- **Background** is solid `shelf`. It replaces `VisualEffectBackground`, which looks gray over dark wallpapers.
- Unchanged: the slide-in animation, the pointer-based choice of screen, and prewarming.

## 6. Top bar (`NavigationBarView`, height 56)

From left to right:

1. The Copyd mark, 24 pt.
2. Board tabs as pills, 32 pt tall. The active tab has a `butter` fill with `onButter` text. Inactive tabs show `ink2` text, and a pinboard tab adds an 8 pt dot in that board's existing color. The "+" (new pinboard) button follows the tabs.
3. The search field, centered in the remaining space, up to 420 pt wide, 34 pt tall, with a `chip` fill. It shows a "⌘F" hint at its trailing edge. Wire ⌘F to focus the field if it does not already do so.
4. The sync chip (`#if CLOUDSYNC`, only while sync is on). It shows a lock icon and the engine's short status: "Synced · now" / "Synced · 2 min", "Syncing…", or "Sync paused" for any error, account or quota state. Clicking it opens Settings.
5. The "…" (more actions) button and the clear-history button. Both are 32 pt icon buttons in `ink2`.

The existing behavior of every control is preserved: renaming and deleting pinboards, drop targets on tabs, and so on.

## 7. Cards (`ClipboardCardView` and `CardContent/*`)

- **Size**: 200 × 220 pt, 12 pt apart, with 16 pt padding at both ends of the strip.
- **Layout**: a header row, a preview well that fills the space left, and a footer row. The card has 10 pt padding, a `card` fill and a 1 pt `line` border.
- **Header** (11 pt semibold, `ink2`): type icon and label, then the relative time and the source app icon (16 pt, corner radius 4) on the trailing side.
- **Footer** (11 pt, `ink2`):
  - Images: dimensions and size.
  - Text and HTML: character count.
  - Links: the source app name.
  - Colors: the hex value, in monospace.
  - Files: under `CLOUDSYNC`, "Stays on this Mac"; otherwise the file size.
  - The "…" menu button stays at the trailing end.
- **Previews by type**:
  - Image: aspect-fill, clipped to the well's radius. The checkerboard is removed, and a transparent image shows the `chip` fill behind it.
  - Text and HTML: 13 pt body text in `ink`, filling the well, with a bottom fade mask when the text overflows.
  - Link: the domain in 17 pt bold on top of a `chip` well, and the path below it in 11 pt monospace `ink2`.
  - Color: the whole well filled with the color.
  - File: the file icon (36 pt) and its name centered in a `chip` well.
- **States**:
  - Default: `line` border.
  - Hover: a slight lift, as today.
  - Selected: a 3 pt `butter` ring outside a 1 pt `butter` border, replacing today's blue border.
  - Keyboard focus follows the selected state.
  - Dragging: unchanged.

## 8. Quick paste with ⌘-number

### Shortcuts

| Keys | Action |
|---|---|
| ⌘1–⌘9 | Paste the Nth visible card of the current tab, the same as pressing Return on it |
| ⇧⌘1–⇧⌘9 | Paste it as plain text, the same as ⇧Return |
| ⌥⌘1–⌥⌘9 | Switch tabs (moved from ⌘1–⌘9) |

- Both the number row and the numeric keypad work. Any other modifier combination is not a shortcut.
- The panel's local key monitor handles these shortcuts before the search-field pass-through, as it does for tab shortcuts today.

### Numbering

- Numbers follow the scroll position. ⌘1 is the leftmost visible card, and ⌘2–⌘9 are the next eight cards in order.
- Each grid (`CardGridView`, `PinboardGridView`) reports its leftmost visible item index to a new `AppState.firstVisibleIndex`, using `.scrollTargetLayout()` with `.scrollPosition(id:)` (available on macOS 14).
- A number with no card behind it does nothing and is consumed, so the keystroke never reaches the frontmost app.
- The paste path is the existing one: `skipNextChange` → paste → hide panel.

### Hints

- While ⌘ is held with the panel open, each numbered card shows a badge at its top-leading corner: `butter` fill, `onButter` text, 11 pt semibold, reading "⌘1" … "⌘9".
- A `flagsChanged` local monitor in `PanelController` sets `AppState.isCommandHeld`, and the flag resets when the panel hides.
- Tab tooltips show "⌥⌘N".

### Pure units

- `QuickPasteShortcut` (new, `Clipbara/Utilities/QuickPasteShortcut.swift`): maps (keyCode, modifiers) to an optional (number 0–8, plainText) pair, and maps (number, firstVisibleIndex, itemCount) to an optional item index.
- `PanelTabShortcut`: the required chord becomes `[.command, .option]`, and the hint becomes "⌥⌘N".

## 9. Accessibility

- Every card keeps a button role. Its VoiceOver label reads the type, the content summary and the source app, and adds "Command N to paste" while it is numbered.
- Number badges are decorative, because the shortcut is already part of the label.
- Contrast:
  - `ink2` on `card` reaches 4.5:1 in both modes.
  - `onButter` on `butter` is about 11:1.
  - The selection ring does not rely on hue alone: it is thicker than the default border.

## 10. Testing

- **Unit tests (TDD):**
  - `QuickPasteShortcutTests`:
    - each digit on the number row and the keypad;
    - ⌘ alone → paste;
    - ⇧⌘ → plain text;
    - ⌥⌘ and ⌃⌘ → nil;
    - mapping with `firstVisibleIndex` 0 and 12;
    - a number past `itemCount` → nil.
  - `PanelTabShortcutTests`: updated so that ⌥⌘ matches and ⌘ alone no longer does.
  - A static, testable `PanelController.panelFrame(visibleFrame:height:)`: full width, bottom-aligned.
- **Visual check**, by the user with the built app:
  - light and dark mode;
  - a 1512 pt and a 1920 pt wide screen;
  - a bottom Dock and a hidden Dock;
  - each card type;
  - hold ⌘ to see the numbers, ⌘3 pastes the third visible card, and the result still holds after scrolling.
- Both targets build, and the existing 129 tests keep passing.
