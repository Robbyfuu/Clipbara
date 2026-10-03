# Copyd for iPhone: pinboards in the keyboard, Shortcuts, widget, and Share

- **Date:** 2026-10-03
- **Status:** Draft, pending the user's approval
- **Branch:** `feat/ios-app`. This builds on the iOS app spec `2026-10-02-ios-app-design.md`.
- **Requested by:** the user, after the device check passed. They chose all four features.

## 1. Goal

Make saving to Copyd and pasting from it possible on the iPhone from more places: other apps, the Home Screen, the Lock Screen, Back Tap, and the keyboard's own pinboards.

## 2. Features, in build order

### 2.1 Pinboards in the keyboard

- **Header switch.** The header's Recent/Pinned switch becomes a horizontally scrolling row of chips: **Recent**, **Pinned**, then one chip per pinboard in `displayOrder`, each with its `pinboardDots` color.
  - The active chip uses `keyCap` with a shadow.
  - Every chip is at least 44 pt tall.
- **Feed.** `KeyboardFeed.Mode` gains `.pinboard(UUID)`. That mode returns the board's entries in entry order, with the same limit and exclusions as the other modes.
  - Add tests: the order, a foreign board's entries excluded, file clips excluded.
- **Height.** The keyboard height stays 280 pt.

### 2.2 Shortcuts, Back Tap and the Action button (App Intents, in the app target)

| Intent | Runs | What it does |
|---|---|---|
| **Save Clipboard** | Opens Copyd | Runs the same path as the Save Clipboard quick action. iOS only lets the foreground app read the pasteboard, so the intent has to open the app. |
| **Save Text to Copyd** (parameter: text) | In the background | Saves the given text as a clip, using `ClipCapture` and the 10 s duplicate rule. This gives a silent capture: Shortcuts' own "Get Clipboard" feeds it. |
| **Copy Latest Clip** | In the background | Copies the newest clip to the pasteboard (an image goes through `PasteboardImage`) and also returns its text as the intent's output. |

- **App Shortcuts.** An `AppShortcutsProvider` exposes "Save clipboard in Copyd" and "Copy last clip from Copyd". They appear in Shortcuts, Spotlight and Siri, and they can be assigned to Back Tap or the Action button.
- **Settings card.** Settings gets a short "Shortcuts & Back Tap" card with the steps to assign one.

### 2.3 Widget (new extension `CopydWidget`)

- **Sizes:**
  - Home Screen small: the latest clip.
  - Home Screen medium: the latest 3 clips.
  - Lock Screen rectangular: the latest clip's preview.
- **Data.** The widget reads the App Group store read-only, through `KeyboardFeed`, the same way the keyboard does. It never reads `rawData`; images show their thumbnails.
- **Tap.** Tapping a clip opens `copyd://copy/<uuid>`. The app copies that clip and shows "Copied".
  - A widget can't reliably write the pasteboard from its own process, so the app does the copy.
  - The `copy` route only writes to the pasteboard and never reads it, so it is safe to accept from any link.
- **Refresh.** The app calls `WidgetCenter.shared.reloadAllTimelines()` after remote changes are applied and after any local save. The timeline policy is `.never`.

### 2.4 Share to Copyd (new extension `CopydShare`)

- **Where it appears.** "Copyd" shows up in the share sheet for text, URLs and images. It saves the shared content without the "Allow Paste" prompt, because sharing hands the content over directly.
- **One writer.**
  - The extension never opens the SwiftData store. It writes each shared item to an inbox in the App Group: `Inbox/<uuid>.json`, plus a payload file for images.
  - The app drains the inbox at launch and whenever it returns to the foreground. It inserts the items through its own context, so the tracker uploads them, applying `ClipCapture` and the duplicate rule. Then it deletes the inbox files.
  - This keeps the database to a single writer and avoids cross-process change tracking.
- **UI.** The extension shows a small sheet in the brand style with the content preview and a **Save** button, then closes with a "Saved" check.
- **Known limitation.** A shared item reaches the Mac only the next time Copyd is opened on the iPhone. The sheet says "Saved. It syncs next time you open Copyd."

## 3. Identity and account changes (need the user's confirmation)

| Target | Bundle ID | Entitlements |
|---|---|---|
| `CopydWidget` | `com.robbyfuu.copyd.widget` | App Group `group.com.robbyfuu.copyd` |
| `CopydShare` | `com.robbyfuu.copyd.share` | App Group `group.com.robbyfuu.copyd` |

The first signed device build creates both App IDs in the Apple Developer account, with the App Group attached. This is permanent, so the user must confirm it first. App Intents need no entitlement.

## 4. Non-goals

- Search inside the keyboard.
- Editing clips from the widget.
- Background CloudKit upload from the Share extension.
- An iPad-specific layout.

## 5. Testing

- **Unit tests (TDD, `CopydTests`):**
  - `KeyboardFeed` pinboard mode.
  - Intent logic, factored into pure functions: the save-text path through `ClipCapture` plus the duplicate rule, and choosing the latest clip.
  - Inbox encoding and decoding, and the drain: duplicates skipped, files removed after import.
  - The `copy/<uuid>` route parsing.
- **Simulator:** builds of every target, plus screenshots of the keyboard chips and the widget (the widget through a preview harness or `#Preview` snapshot).
- **On the user's iPhone:**
  - Pinboard chips.
  - A Back Tap shortcut.
  - Copy Latest Clip.
  - A widget tap.
  - Share from Safari and from Photos, then open Copyd and see the clip reach the Mac.
