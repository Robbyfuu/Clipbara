# iPhone app and paste keyboard: device check

- **Date:** 2026-10-03
- **Device:** iPhone 17 Pro Max running iOS 27, signed Debug build, CloudKit Development environment.
- **Mac:** Debug build from this branch, signed in to the same iCloud account as the iPhone.
- **Spec:** `docs/superpowers/specs/2026-10-02-ios-app-design.md` §9 step 4.

## Results

| # | Check | Result |
|---|---|---|
| 1 | Install `CopydiOS`, open it, and see the Mac's history arrive | Pass, after fix `cf44d64` (see below) |
| 2 | Add the keyboard and allow Full Access | Pass |
| 3 | Insert a text clip from the keyboard in WhatsApp | Pass |
| 4 | Tap an image in the keyboard, then paste it with touch-and-hold | Pass |
| 5 | Pin and delete a clip on the iPhone, and see both changes on the Mac | Pass |
| 6 | With Full Access off, the keyboard shows the steps and the bottom row still types | Pass |
| 7 | iPad layout | Not run (no iPad at hand) |

## Found during the check

- **Uploads lost after the Mac app's binary was deleted.**
  - Cause: a clean rebuild deleted the binary of the running Mac app. After that, every save failed with `CKError 1: Client went away before operation … could be validated`, and `handleSent` dropped each failed save for good.
  - Effect: the six newest clips never reached the iPhone.
  - Fix: `cf44d64`. When sync starts with saved state, it queues again every record whose `syncSystemFields` is nil, meaning iCloud never confirmed it. After relaunch, the Mac re-queued 13 records, and all 57 eligible clips were confirmed.
- **The design did not follow the approved concept artboards.**
  - The first build used plain system lists. The user rejected it ("feísimo").
  - Rebuilt to the iPhone history and keyboard artboards in `2227cf8` and `d0c02ed`.
  - Polished after a device screenshot in `39e4e2e` and `29ee086`: a transparent keyboard root over the system keyboard glass, native-style key caps, single-URL clips shown as links, and large short codes.
  - User verdict: "ahora se ve mucho mejor".

## Known limitations

- Copying an old clip on the iPhone reaches the Mac through Universal Clipboard. The Mac captures it as a new clip, because the duplicate rule only merges copies made within 60 s.
- The keyboard's "Updated N min ago" comes from the app's last sync. It goes stale until the app is opened or a push arrives.
