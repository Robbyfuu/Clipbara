# iCloud sync — two-Mac verification

Status: **pending**. Mac A is set up; Mac B is not.

## Setup

| Step | Mac A (2026-10-02) | Mac B |
|---|---|---|
| Build `Copyd` Debug → `Copyd.app` | done | pending |
| Launch with `--args -CopydDebugOriginalAppVersion 1.0` | done | pending |
| Settings → General → Sync with iCloud on | done; first upload finished 09:41:39 with no CloudKit errors | pending |

Mac B, same Apple ID in iCloud and in Xcode → Settings → Accounts:

```sh
git clone https://github.com/Robbyfuu/Clipbara.git ~/Code/Copyd && cd ~/Code/Copyd && git checkout feat/panel-redesign
brew install xcodegen && xcodegen generate
xcodebuild -project Copyd.xcodeproj -scheme Copyd -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
open -n "$PWD/DerivedData/Build/Products/Debug/Copyd.app" --args -CopydDebugOriginalAppVersion 1.0
```

Quit other clipboard managers on both Macs during the test. The CloudKit Development database already holds a few `copyd-sync-check-…` test clips.

## Checklist (spec §13)

| # | Check | Result | Latency / notes |
|---|---|---|---|
| 1 | Text copied on Mac A appears on Mac B (target ≤ 15 s) | | |
| 2 | Pin, rename and delete on Mac B propagate to Mac A | | |
| 3 | Pinboard create, rename, reorder and delete propagate | | |
| 4 | A 5 MB image arrives intact with a thumbnail | | |
| 5 | A Universal Clipboard copy ends as one clip on both Macs | | |
| 6 | CloudKit Console (Development, zone `Clipboard`): `Clip` records show only encrypted fields and an asset | | |
| 7 | `Copyd` target builds and the unit tests pass | pass (2026-10-02, 146 tests on `feat/panel-redesign`) | |

## Plan risks checked here

| Risk | Result |
|---|---|
| 3 · With Mac B's panel closed, its menu-bar latest items update after a copy on Mac A (push delivery) | |
| 4 · Sync works without `com.apple.security.network.client` | pass on Mac A (upload succeeded) |
| Review focus 1 · Disable and re-enable sync on Mac B: no clip is deleted | |

## Known behavior to expect

- Enabling the second Mac merges both histories, and the first copy afterwards trims the union to the smaller `historyLimit` on both Macs.
- Clips deleted on a Mac while its sync was off come back when sync is re-enabled.
- File clips (`.fileURL`) and clips over 20 MB stay on the Mac that copied them.
