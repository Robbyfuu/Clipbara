# Copyd — Claude Code project notes

Copyd is a macOS clipboard manager whose history syncs across Macs through iCloud. It is a fork of Clipbara (mobrava/Clipbara, GPL-3.0). The fork ships only the App Store build; the DMG/Sparkle build was removed.

## Build and run

- **Generate the project:** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate`. This produces `Copyd.xcodeproj`, which is gitignored.
- **Build:**
  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Copyd.xcodeproj -scheme Copyd -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build
  ```
- **Test** (unhosted unit tests in `Tests/`):
  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Copyd.xcodeproj -scheme CopydTests -destination 'platform=macOS' -derivedDataPath DerivedData
  ```
  `CopydTests` lists its sources explicitly in `project.yml`. Add any new pure file it needs there.
- **After a successful build, always quit the running app and relaunch it.** Kill it by full path only, so no other app is ever touched:
  ```
  pkill -f "$PWD/DerivedData/Build/Products/Debug/Copyd.app/Contents/MacOS/Copyd" || true
  sleep 1
  open -n "$PWD/DerivedData/Build/Products/Debug/Copyd.app" --args -CopydDebugOriginalAppVersion 1.0
  ```
  `-CopydDebugOriginalAppVersion 1.0` bypasses the paywall in Debug builds. It is a launch argument, so it applies only to that launch.
- Paste (Setapp) also uses ⌘⇧V and sometimes takes the shortcut first. Quit it while testing Copyd.

## Release (App Store only)

- Run `bash scripts/build-mas.sh` to archive and export a signed `.pkg`.
- Run `UPLOAD=1 bash scripts/build-mas.sh` to upload to App Store Connect.
- **Not ready yet.** Before the first App Store build:
  - The script still holds upstream's `TEAM_ID` and certificate names. Switch them to team `TQC76W2BKK`.
  - Create the provisioning profile "Copyd Mac App Store" for `com.robbyfuu.copyd`.
  - Create the in-app purchases `com.robbyfuu.copyd.trial7day` and `com.robbyfuu.copyd.lifetime`.
  - Deploy the CloudKit schema to Production and set `aps-environment` to `production`.
  - Resolve the GPL-3.0 licensing with upstream. The App Store build cannot ship until this is settled.
- Version numbers live in `Copyd/Info.plist` (`CFBundleShortVersionString`, `CFBundleVersion`).

## Identity

| Item | Value |
|---|---|
| Bundle ID | `com.robbyfuu.copyd` |
| Team | `TQC76W2BKK` |
| iCloud container | `iCloud.com.robbyfuu.copyd` (permanent) |
| Targets / schemes | `Copyd` (app), `CopydTests` |
| Logger subsystem | `com.robbyfuu.copyd` (sync logs use category `Sync`) |

**Never rename these.** Existing history depends on them:
- The `StoreManager` store constants `com.minsang.PasteClip`, `PasteClip.store` and `.PasteClip_SUPPORT`. The store lives at that path inside the sandbox container.
- UserDefaults keys (`historyLimit`, `iCloudSyncEnabled`, …).
- The CloudKit zone `Clipboard` and the record types `Clip`, `Pinboard` and `PinboardEntry`.

## iCloud sync (`Copyd/Sync/`)

- Sync runs on `CKSyncEngine` against the user's private database. Spec: `docs/superpowers/specs/2026-10-01-icloud-sync-design.md`.
- **End-to-end encryption.** Fields go in `encryptedValues`. Payloads over 256 KB (`rawData`, plus long text in `textPayload`) are sealed with AES-GCM (`AssetCrypto`) before they upload as a `CKAsset`.
- **What syncs:**
  - File clips (`.fileURL`) and clips over 20 MB never sync.
  - Clean-up from `historyLimit` does sync.
  - Universal Clipboard duplicates are merged by `DuplicateRule`.
- **Change capture.** `LocalChangeTracker`, an observer on `willSave`, is the only place local changes are captured. **Every SwiftData write made by the sync layer must run inside `tracker.suppressing(ids)`**, or it echoes back to iCloud.
- **Store configuration.** `ModelConfiguration(..., cloudKitDatabase: .none)` is required. With the iCloud entitlement present, SwiftData would otherwise try to mirror on its own and fail to open the store.
- **Environment.** Debug builds use the CloudKit **Development** environment.
- **Two-Mac check.** The pending verification is in `docs/testing/icloud-sync.md`.

## History panel

- **Layout.** A full-width bottom shelf, built from `PanelGeometry` and `DesignTokens.Brand`. Spec: `docs/superpowers/specs/2026-10-02-panel-redesign-design.md`.
- **Colors come only from `DesignTokens.Brand`**, which holds dynamic light/dark tokens. Views never use literal colors, though `Color.clear` is fine.
- **Liquid Glass, macOS 26 and later** (`if #available(macOS 26, *)`). The shelf and the top-bar controls use `glassEffect`; macOS 14–15 keep the solid shelf. `Glass.tint` does not render while the app is inactive, and this panel is non-activating, so paint the tint as a fill over the glass instead.
- **Panel shortcuts:**
  - ⌘1–9 paste the Nth visible card.
  - ⇧⌘1–9 paste it as plain text.
  - ⌥⌘1–9 switch tabs.
  - ⌘F focuses search.

  Quick-paste numbering is derived from the scroll offset (`QuickPasteShortcut.firstVisibleIndex`, using the left-edge rule). Do not use `.scrollPosition`: it misses programmatic `scrollTo`.

## Project rules

- **Language and platform.** Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`), targeting macOS 14+.
- **SwiftData.** Do not use `#Index` or `#Unique`, which require macOS 15.
- **SwiftData saves.** After any insert, delete or update, call `try? modelContext.save()`. Do not rely on autosave. Sync code uses `do`/`catch` and logs the error.
- **`skipNextChange` pattern.** Call `ClipboardMonitor.skipNextChange()` before every paste. `AppState.paste` already does this.
- **Panel window.** The panel is an `NSPanel` (non-activating) that hosts SwiftUI through `NSHostingView`.
- **View lifecycle.** Inside `NSHostingView`, never show or hide a view that has `@Query` with `if`/`else`. Use the ZStack + opacity pattern instead.
- **Dependencies.** KeyboardShortcuts via SPM. Sparkle has been removed.
- **Docs.** Specs, plans and test records live in `docs/superpowers/` and `docs/testing/`.
