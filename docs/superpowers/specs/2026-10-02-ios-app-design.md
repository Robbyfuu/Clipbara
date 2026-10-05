# Copyd for iPhone and iPad, with a paste keyboard

- Date: 2026-10-02
- Status: Draft, pending review
- Branch: `feat/ios-app`, stacked on `feat/panel-redesign` (PR #1). It needs the Copyd rename and the sync code.
- Builds on: `docs/superpowers/specs/2026-10-01-icloud-sync-design.md`. Its CloudKit schema was designed so an iOS client could adopt it unchanged.

## 1. Goal

Paste anything you copied on your Mac into any app on your iPhone or iPad, using a Copyd keyboard.

**Success:** you copy a clip on the Mac, open the Copyd keyboard on the iPhone, and the clip is there. One tap pastes it.

## 2. Decisions (from the user)

- Main value: the paste keyboard.
- Approach A: the iOS app runs the sync and stores the history in an App Group. The keyboard only reads it.
- One universal app for iPhone and iPad, on iOS 17 and later (a requirement of `CKSyncEngine`). Liquid Glass applies on iOS 26 and later.
- No paywall on iOS for now. This build is for personal use.
- No capture on iOS in this cut. Copying on the iPhone and sending the clip to the Mac comes later.
- On an iCloud sign-out or account switch, iOS deletes its local history, because it is only a copy of the cloud. The Mac keeps its own history, as it does today.

## 3. Non-goals

- Capture on iOS: reading the iPhone's pasteboard, a Share extension, or `UIPasteControl`.
- Search inside the keyboard. A keyboard extension has no text field of its own to type into.
- Inserting images from the keyboard. iOS does not allow it. Images are copied to the pasteboard instead (§6).
- Widgets, Shortcuts actions and Apple Watch.
- An App Store submission for iOS.

## 4. Targets and identity

| Target | Type | Bundle ID | Entitlements |
|---|---|---|---|
| `Copyd` | macOS app (existing) | `com.robbyfuu.copyd` | unchanged |
| `CopydiOS` | iOS app, universal | `com.robbyfuu.copyd`, the same ID so one purchase covers both platforms | iCloud (CloudKit, `iCloud.com.robbyfuu.copyd`), push (`aps-environment`), App Group `group.com.robbyfuu.copyd`, background mode `remote-notification` |
| `CopydKeyboard` | iOS keyboard extension, embedded in `CopydiOS` | `com.robbyfuu.copyd.keyboard` | App Group `group.com.robbyfuu.copyd`; `RequestsOpenAccess = YES` in its `NSExtension` attributes |
| `CopydTests` | macOS unit tests (existing) | unchanged | — |

Creating the keyboard App ID, the App Group and push for iOS in the Apple Developer account is permanent, so the user must confirm it before the first signed build.

## 5. Shared code (`Shared/`)

Files used by more than one target move to a top-level `Shared/` folder. `project.yml` adds that folder to all three app targets and keeps the explicit `CopydTests` source list, with paths updated.

- **Models:** `ClipboardItem`, `ContentType`, `Pinboard`, `PinboardEntry`, `ExcludedApp`.
  - `ClipboardItem.dragProvider()` and the `UTType.copydClipboardItemID` declaration use AppKit. They move to `Copyd/Models/ClipboardItem+Drag.swift`, which only the Mac target compiles.
- **Sync:** `AssetCrypto`, `SyncRecordMapper`, `DuplicateRule`, `SyncBatchPlanner`, `ModelSnapshots`, `LocalChangeTracker`, `RemoteApplier`, `CloudSyncEngine`.
- **Thumbnails:** `Thumbnail.png(from:maxSize:)` is rewritten with ImageIO (`CGImageSourceCreateThumbnailAtIndex`) and `UTType.png` output, so it builds on both platforms.
  - The signature stays the same and the existing `ThumbnailTests` must still pass.
  - Keep that test's size assertions; if ImageIO rounds differently, report it rather than loosening the test.
- **Platform differences inside `CloudSyncEngine`, behind `#if os(macOS)` / `#else`:**
  - **Remote notifications:** `NSApplication.shared.registerForRemoteNotifications()` on macOS, `UIApplication.shared.registerForRemoteNotifications()` on iOS.
  - **Account change:** sign-out or switch on iOS also deletes every local `ClipboardItem`, `Pinboard` and `PinboardEntry`, inside `tracker.suppressing`, and saves. macOS keeps them.
  - **Last sync time:** on iOS, each time the status becomes `.upToDate(date)`, the engine writes `date` to `UserDefaults(suiteName: "group.com.robbyfuu.copyd")` under the key `lastSyncAt`. The keyboard shows it.

The Mac keeps its current store path through `StoreManager`. Nothing about the Mac's data or behavior changes.

## 6. iOS app (`CopydiOS/`)

- **Store:** `SharedStore.url(groupContainer:)`, a pure function returning `<group container>/Library/Application Support/Copyd/Copyd.store`. It creates the directory.
  - The app opens it with `ModelConfiguration(url:, cloudKitDatabase: .none)`.
  - `SyncState.data` lands next to it, because `CloudSyncEngine` already writes its state beside the store.
- **Sync:** on by default on iOS. Register the default `iCloudSyncEnabled = true` before `CloudSyncEngine` reads the key. The engine starts at launch.
- **Tabs (SwiftUI `TabView`):**
  - **History.** A list of clips, newest first, with search and a type filter (All / Text / Links / Images). Each row shows a preview, the source device or app, and the relative time.
    - Tap a row to copy the clip to `UIPasteboard.general` and show a "Copied" toast.
      - Text, links, HTML and colors copy as plain `textContent`, or the hex for colors.
      - Images copy as PNG: `UIImage(data: rawData)?.pngData()`.
    - Swipe actions: pin/unpin and delete. Both propagate to the Mac.
  - **Pinboards.** The pinboards and their clips. Rows behave the same as in History.
  - **Settings.**
    - The sync status line, with the same strings as the Mac.
    - A three-step keyboard guide: Settings → General → Keyboard → Keyboards → Add → Copyd → turn on Allow Full Access.
    - One sentence on why Full Access is needed: so the keyboard can read your history.
- **Look:** follow the "iPhone · history (concept)" artboard and the brand tokens. On iOS 26 and later the system `TabView` and toolbar take Liquid Glass on their own; content rows stay solid.

## 7. Keyboard (`CopydKeyboard/`)

- `KeyboardViewController: UIInputViewController` hosts a SwiftUI view through `UIHostingController`.
- **Data:**
  - It opens the same store read-only: `ModelConfiguration(url: SharedStore.url(...), allowsSave: false, cloudKitDatabase: .none)`.
  - It refetches on every `viewWillAppear`.
  - It never reads `rawData` for images; it uses `thumbnailData`, because the keyboard has a memory budget of about 48–50 MB.
- **Feed:** `KeyboardFeed.items(in:mode:limit:)`.
  - **Recent:** newest first.
  - **Pinned:** clips with `isPinned`.
  - `limit` is 60. File clips never appear, because they never sync.
- **Layout:** follow the "iPhone · keyboard (concept)" artboard.
  - **Header:** the Copyd mark, "Updated · N min ago" built from `lastSyncAt`, and a Recent / Pinned switch.
  - **Grid:** two columns of clip cards, scrollable.
  - **Bottom row:**
    - 🌐 next keyboard, shown only when `needsInputModeSwitchKey` is true. It uses `handleInputModeList(from:with:)`.
    - space, delete (`deleteBackward()`) and return (`insertText("\n")`).

    These keys keep the keyboard usable without Full Access, which App Store guideline 4.4.1 requires.
- **Tap a clip:** `PasteAction.decide(contentType:textByteCount:)` returns either `.insert(text)` or `.copyToPasteboard`.
  - **Insert:** text, links, HTML (its plain `textContent`), rich text (its plain `textContent`) and colors (the hex), each up to 51_200 UTF-8 bytes, go through `textDocumentProxy.insertText`.
  - **Copy to pasteboard:** text longer than that, and every image. The keyboard shows a toast:
    - images: "Copied. Touch and hold the field, then tap Paste."
    - long text: "Copied. It's too long to insert."
  - For an image, it reads `rawData` once at tap time, converts it to PNG and writes it to `UIPasteboard.general`. This needs Full Access.
- **States:**
  - **No Full Access** (`hasFullAccess == false`): the grid area shows "Turn on Allow Full Access to see your history" plus the steps. The bottom row still works.
  - **No store yet** (the app was never opened): "Open Copyd once to connect your history."
  - **Store read error:** an empty grid with "Couldn't load your history." Never crash.

## 8. Errors

| Case | Behavior |
|---|---|
| No iCloud account on the iPhone | The status reads "Sign in to iCloud to see your history". The engine stays dormant (existing behavior). |
| Sign-out or account switch | Turn sync off, delete the engine state, and delete the local history (iOS only, §5). |
| Keyboard without Full Access | The guidance view from §7. The bottom row keeps working. |
| App never opened | The keyboard shows "Open Copyd once…". |
| Text over 50 KB | Copied instead of inserted, with a toast. |
| Image tap without Full Access | Cannot happen: without Full Access the grid is hidden. |

Every other sync error behaves as in the sync spec §11.

## 9. Testing

1. **Spike first, then discarded.** In the iOS simulator, the app writes clips to the App Group store while a second process opens it with `allowsSave: false` and reads them. Confirm both work at once and that the reader sees new rows after a refetch. If they don't, stop and report before any UI work.
2. **Unit tests (TDD)** in `CopydTests`. These units are platform-neutral and compile on macOS:
   - `SharedStore.url(groupContainer:)`: path shape, and the directory is created.
   - `KeyboardFeed.items`: Recent and Pinned ordering, the limit of 60, and file clips excluded. Use an in-memory container with the shared models.
   - `PasteAction.decide`: each content type, the 51_200-byte boundary (inclusive insert), and images always copied.
   - `RelativeSyncTime.text(from:now:)`: "now" under 60 s, then minutes, hours, and "never" for nil.
   - Existing tests keep passing, including `ThumbnailTests` after the ImageIO rewrite.
3. **Builds:** `Copyd` (macOS), `CopydiOS` for the simulator and a generic iOS device, `CopydKeyboard`, and `CopydTests`.
4. **On the user's iPhone (iOS 17+, Developer Mode on, connected by cable the first time):**
   1. Install `CopydiOS`, open it, and see the Mac's history arrive.
   2. Add the keyboard and allow Full Access.
   3. Copy text on the Mac; it shows up in the keyboard. Paste it in Notes and in WhatsApp.
   4. Tap an image; it is copied. Paste it with touch-and-hold.
   5. Pin and delete a clip on the iPhone, and see the change on the Mac.
   6. With Full Access off, the keyboard shows the guidance and the bottom row still types.
   7. On iPad, the same checks, with the keyboard laid out at iPad width.
