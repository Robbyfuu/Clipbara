# Rename the app to Copyd and drop the DMG build

- Date: 2026-10-02
- Status: Draft, pending review
- Branch: `feat/panel-redesign`. These tasks run after the panel redesign tasks and before its visual check, so the user checks the final app once.

## 1. Decisions (from the user)

- The rename covers both what the user sees and the code: names, types, folders, project, targets and schemes.
- The DMG build ("Clipbara", Sparkle auto-update from mobrava's appcast) leaves the fork. Copyd is distributed only through the App Store target.

## 2. Goals

1. No user-visible "Clipbara" or "PasteClip" remains anywhere. This covers menus, windows, alerts, About, onboarding, every translation, the app icon and the menu bar icon.
2. Code, folders, project, targets and schemes are named Copyd.
3. There is a single app target, `Copyd` (bundle `com.robbyfuu.copyd`), with no Sparkle.
4. Existing Copyd data (local store, sync state, settings) survives the rename untouched.
5. The GPL-3.0 license and the attribution to the original project stay intact.

## 3. Non-goals

- Changing paywall behavior. Only its identifiers change (§6).
- Rewriting the README beyond the name, the attribution and the install section.
- Editing historical specs, plans and reports. They keep the old names as written.
- CONTRIBUTING, SECURITY and CODE_OF_CONDUCT. They describe upstream's process; adapting them to the fork is a separate decision.

## 4. Kept on purpose (data compatibility)

These identifiers stay, each with a one-line comment explaining why:

- **`StoreManager` store location:** directory `com.minsang.PasteClip`, file `PasteClip.store`, support dir `.PasteClip_SUPPORT`. They live inside the `com.robbyfuu.copyd` sandbox container. Renaming them would orphan the history already stored on Mac A.
- **Every `UserDefaults` key** (`historyLimit`, `iCloudSyncEnabled`, …), except the two debug keys in §6.
- **The iCloud container** `iCloud.com.robbyfuu.copyd` and the CloudKit schema.

## 5. Removed: the DMG build

`project.yml` loses:
- the `Clipbara` target
- the `Sparkle` package
- the `KeyboardShortcuts` entry, only if it ends up unused (it is not; it stays)

The app's `#if APPSTORE` and `#if CLOUDSYNC` conditions become always true, and `#if !APPSTORE` always false. That covers 24 sites. Each conditional is resolved:
- Keep the true branch and delete the false one.
- Remove `APPSTORE` and `CLOUDSYNC` from `SWIFT_ACTIVE_COMPILATION_CONDITIONS`.

**Files deleted:**

| File | Why |
|---|---|
| `Clipbara/Info.plist` | The DMG target's Info.plist (Sparkle keys, mobrava feed) |
| `Clipbara/Clipbara.entitlements` | The DMG target's entitlements |
| `Clipbara/Services/UpdaterService.swift` | Sparkle updater, only used by the DMG build |
| `scripts/build-release.sh` | Builds, signs and notarizes the DMG and updates the Sparkle appcast |
| `appcast.xml` | mobrava's Sparkle feed |
| `Casks/clipbara.rb` | Homebrew cask for the DMG |

Git history keeps all of them.

`scripts/test-and-launch.sh` and `scripts/build-mas.sh` are kept and renamed to Copyd.

## 6. Renamed

| What | From | To |
|---|---|---|
| Source folder | `Clipbara/` | `Copyd/` |
| XcodeGen project name | `Clipbara` | `Copyd` (`Copyd.xcodeproj`) |
| App target and scheme | `ClipbaraMAS` | `Copyd` |
| Test target and scheme | `ClipbaraTests` | `CopydTests`, bundle `com.robbyfuu.copyd.tests` |
| `options.bundleIdPrefix` | `com.minsang` | `com.robbyfuu` |
| Info.plist / entitlements | `Info-MAS.plist`, `Clipbara-MAS.entitlements` | `Info.plist`, `Copyd.entitlements` |
| Types and identifiers | `ClipbaraApp`, `ClipbaraPanel`, `pasteClipClipboardItemID`, any other symbol containing Clipbara/PasteClip | `CopydApp`, `CopydPanel`, `copydClipboardItemID`, … |
| Exported UTType | `com.minsang.PasteClip.clipboard-item-id` | `com.robbyfuu.copyd.clipboard-item-id` (Info.plist declaration updated too) |
| Logger subsystems | `com.minsang.PasteClip` | `com.robbyfuu.copyd` |
| StoreKit product IDs | `com.minsang.Clipbara.trial7day`, `.lifetime` | `com.robbyfuu.copyd.trial7day`, `.lifetime` |
| StoreKit config | `StoreKit/Clipbara.storekit` | `StoreKit/Copyd.storekit` |
| Debug keys | `ClipbaraDebugOriginalAppVersion`, `ClipbaraDebugTrialShiftDays` | `CopydDebugOriginalAppVersion`, `CopydDebugTrialShiftDays` |
| Visible strings | "Clipbara" in Swift strings and `Localizable.xcstrings` (all languages; brand name untranslated) | "Copyd" |
| Onboarding import hint | "Coming from PasteClip" | "Coming from Clipbara?" (the JSON import still accepts Clipbara backups) |
| `MenuBarExtra` title | "Clipbara" | "Copyd" |

## 7. Icons

- **App icon:** the dark variant from the brand canvas, a squircle in ink with a butter card and a paper stem (logo B, counter hole).
  - The source SVG is committed at `design/icon/copyd-icon.svg`, with the same canvas and inset as the current icon (1024 × 1024, a 824 × 824 squircle, centered, with a drop shadow).
  - The seven PNGs in `AppIcon.appiconset` (16–1024) are rendered with `rsvg-convert`.
- **Menu bar icon:** the mark as a template image, `MenuBarMark` in the asset catalog.
  - It is a vector PDF rendered from the mark SVG with `rsvg-convert -f pdf`, marked as a template with preserved vector data.
  - It is drawn as one shape, so the counter hole stays visible in monochrome.
  - `MenuBarExtra` switches from `systemImage: "clipboard"` to that image.

## 8. Docs

- **`README.md` and `README.zh-CN.md`:**
  - The product name becomes Copyd.
  - The DMG and Homebrew install sections are replaced by "Build from source" plus a note that the App Store build is coming.
  - A line is added: "Copyd is a fork of [Clipbara](https://github.com/mobrava/Clipbara) by mobrava, licensed under GPL-3.0."
- **`LICENSE`:** unchanged.
- **`docs/testing/*.md`:** the commands use the new scheme, product path and debug key.
- **The local `CLAUDE.md`:** it is gitignored, so it is not part of the commit. Its build and release sections are updated to the `Copyd` scheme, and the DMG release steps are removed.

## 9. Testing

- `xcodegen generate` succeeds. The `Copyd` scheme builds, and `CopydTests` runs the full suite, with every test passing.
- Search the tracked source for leftover names:

  ```
  grep -rIn "Clipbara\|PasteClip\|minsang" Copyd Tests project.yml StoreKit README*.md
  ```

  The only matches allowed are the §4 store identifiers and the README attribution line.
- **Data survival:**
  1. Launch the renamed app on Mac A.
  2. The history synced earlier is still there.
  3. Settings still shows "Sync with iCloud" on and reaches "Up to date".
- **Icons:** visual check in Task 7, both the Dock icon and the menu bar icon in light and dark mode.
