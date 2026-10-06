# Copyd — Claude Code project notes

Copyd is a clipboard manager whose history syncs through iCloud across Macs, iPhones and iPads. The iPhone/iPad app ships a paste keyboard. It is a fork of Clipbara (mobrava/Clipbara, GPL-3.0). The fork ships only the App Store build; the DMG/Sparkle build was removed.

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
- **Never run `xcodebuild clean` or delete `DerivedData/` while Copyd runs from it.** The running app loses its binary, and cloudd then rejects every upload (`Client went away before operation … could be validated`).
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
| Targets / schemes | `Copyd` (macOS app), `CopydiOS` (iPhone/iPad app, same bundle ID), `CopydKeyboard` (keyboard extension), `CopydTests` |
| Keyboard bundle ID | `com.robbyfuu.copyd.keyboard` |
| App Group | `group.com.robbyfuu.copyd` (iOS store and `lastSyncAt`) |
| Logger subsystem | `com.robbyfuu.copyd` (sync logs use category `Sync`) |

**Never rename these.** Existing history depends on them:
- The `StoreManager` store constants `com.minsang.PasteClip`, `PasteClip.store` and `.PasteClip_SUPPORT`. The store lives at that path inside the sandbox container.
- UserDefaults keys (`historyLimit`, `iCloudSyncEnabled`, …).
- The CloudKit zone `Clipboard` and the record types `Clip`, `Pinboard` and `PinboardEntry`.

## iCloud sync (`Shared/Sync/`)

- Sync runs on `CKSyncEngine` against the user's private database. Spec: `docs/superpowers/specs/2026-10-01-icloud-sync-design.md`.
- **End-to-end encryption.** Fields go in `encryptedValues`. Payloads over 256 KB (`rawData`, plus long text in `textPayload`) are sealed with AES-GCM (`AssetCrypto`) before they upload as a `CKAsset`.
- **What syncs:**
  - File clips (`.fileURL`) and clips over 20 MB never sync.
  - Clean-up from `historyLimit` does sync.
  - Universal Clipboard duplicates are merged by `DuplicateRule`.
- **Change capture.** `LocalChangeTracker`, an observer on `willSave`, is the only place local changes are captured. **Every SwiftData write made by the sync layer must run inside `tracker.suppressing(ids)`**, or it echoes back to iCloud.
- **Store configuration.** `ModelConfiguration(..., cloudKitDatabase: .none)` is required. With the iCloud entitlement present, SwiftData would otherwise try to mirror on its own and fail to open the store.
- **Environment.** Debug builds use the CloudKit **Development** environment.
- **Recovery.** On start with saved state, records iCloud never confirmed (`syncSystemFields == nil`) are queued again, so a failed upload heals on the next launch.
- **iOS differences** (`#if os(iOS)`): an account change or a deleted zone wipes the local mirror and restarts sync; `.upToDate` writes `lastSyncAt` to the App Group defaults.
- **Two-Mac check.** The pending verification is in `docs/testing/icloud-sync.md`.

## iPhone/iPad app and keyboard

- Spec: `docs/superpowers/specs/2026-10-02-ios-app-design.md`. Device check: `docs/testing/ios-app.md`.
- **Shared code** (models, sync, brand tokens, `CopydMark`, `CopydWordmark`, pure units) lives in `Shared/` and compiles into every target. Mac-only code stays in `Copyd/`.
- **Simulator build** (no provisioning flags):
  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Copyd.xcodeproj -scheme CopydiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData build
  ```
- **Device build and install** (separate derived data so it never collides with Mac builds):
  ```
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Copyd.xcodeproj -scheme CopydiOS -configuration Debug -destination 'id=<udid>' -derivedDataPath DerivedData-device -allowProvisioningUpdates build
  xcrun devicectl device install app --device <udid> DerivedData-device/Build/Products/Debug-iphoneos/Copyd.app
  ```
- **Store.** The app writes `Copyd.store` in the App Group; the keyboard opens it read-only (`allowsSave: false`) and checks `SharedStore.storeExists` first, because opening a missing file throws.
- **Keyboard memory (~48–50 MB).** Rows and cards use `thumbnailData` only; `rawData` is read once, for the tapped image, through `PasteboardImage`.
- **Keyboard look.** Transparent root so the system keyboard glass shows; cards and keys use `keyCap`. Keep space/delete/return: guideline 4.4.1 needs a keyboard that types without Full Access.
- **DEBUG seed.** `-CopydSeedSampleClips YES -iCloudSyncEnabled NO` inserts `seed-*` clips; any other DEBUG launch deletes them before sync starts. Always pass `-iCloudSyncEnabled NO` with the seed.

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
- **Card tools:**
  - ⇧⌥Return opens Paste as…
  - ⌥Return pastes the text recognized in an image.
  - ⌘E opens Edit.

  These shortcuts live in `CardShortcut`. With 2 or more cards selected, every tool except Edit beeps.

## Clip tools (spec: `docs/superpowers/specs/2026-10-04-clip-tools-design.md`)

- **Secrets (`isSensitive`) are local-only.** The hard gate is `SyncRecordMapper.isEligible(..., isSensitive:)` when the batch is built, so never add an upload path that skips it.
  - Never flag an existing clip in place. An edit that turns a clip into a secret deletes it and inserts a new local clip (`ClipEdit`).
  - The sweep skips pinned clips and clips on a pinboard, and stops while "Protect secrets" is off.
- **OCR fields (`ocrText`, `ocrDone`) are local-only and never mapped.**
  - Vision runs on a utility GCD queue. `ImageTextRecognizer` is excluded from the keyboard, widget and share targets.
  - A failed read leaves `ocrDone == false`, so the next fill retries it.
- **Transforms (`TextTransform`)** decide applicability from the first 4 KB (`menuProbeLimit`) and apply to the full text. Clips with `isSensitive` never get Paste as.

## System integration and previews (spec: `docs/superpowers/specs/2026-10-05-everywhere-previews-design.md`)

- **Controls and Lock Screen widgets** live in `CopydWidget`.
  - The intents are compiled into both the app and the widget. The app-only body sits behind `WIDGET_EXTENSION`, and the extension copy sets `isDiscoverable = false`.
  - Never expose save-clipboard as a URL: `QuickRoute.allowsURL` must stay false for it.
- **Link previews** (`linkTitle`, `linkImageData`, `linkPreviewDone`) are local-only and never mapped.
  - They are fetched in the app only, never in an extension.
  - Never fetched: secrets, single-use links (token/code/reset… query names, `#…=` fragments, reset/verify paths) and local or private hosts (`LinkPreviewPlan.fetchableURL`).
  - The Mac needs `com.apple.security.network.client`.
- **Spotlight** is iPhone and iPad only (`SpotlightIndexer`).
  - It indexes every clip except secrets, including text that `SecretDetector` flags.
  - It follows main-context saves and reconciles through `spotlightIndexVersion`.
  - Tapping a result goes through `SceneDelegate` into `QuickRoute.copy`. File clips open the share sheet.
- **The keyboard feed** must use `propertiesToFetch` (`KeyboardFeed.cardFields`). Never load `rawData` or `linkImageData` there.
- **Code highlighting** uses `CodeDetector` and `SyntaxHighlighter` on the first 2 KB, with tokens cached by `contentHash`. The code colors are WCAG ≥ 4.5:1 on `chip` and `card`.
- **Spanish strings:** `python3 scripts/check_es.py` must report `0 missing`.

## Project rules

- **Language and platform.** Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`), targeting macOS 14+ and iOS 17+.
- **SwiftData.** Do not use `#Index` or `#Unique`, which require macOS 15.
- **SwiftData saves.** After any insert, delete or update, call `try? modelContext.save()`. Do not rely on autosave. Sync code uses `do`/`catch` and logs the error.
- **`skipNextChange` pattern.** Call `ClipboardMonitor.skipNextChange()` before every paste. `AppState.paste` already does this.
- **Panel window.** The panel is an `NSPanel` (non-activating) that hosts SwiftUI through `NSHostingView`.
- **View lifecycle.** Inside `NSHostingView`, never show or hide a view that has `@Query` with `if`/`else`. Use the ZStack + opacity pattern instead.
- **Dependencies.** KeyboardShortcuts via SPM. Sparkle has been removed.
- **Docs.** Specs, plans and test records live in `docs/superpowers/` and `docs/testing/`.
