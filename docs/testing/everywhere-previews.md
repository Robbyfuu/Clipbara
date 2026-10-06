# System integration and previews: device check

- **Date:** 2026-10-06
- **Spec:** `docs/superpowers/specs/2026-10-05-everywhere-previews-design.md` §8
- **Automated coverage:** 575 unit tests pass, and both the Mac build and the iOS simulator build succeed.
- **iOS 27 simulator checks:**
  - Controls appear in the Control Center gallery and open the right route.
  - The circular and inline Lock Screen widgets render through the harness.
  - A link row shows the title and image.
  - Spotlight finds a seeded clip and never a seeded secret.
  - Code and color rows render.

## Results

| # | Check | Result |
|---|---|---|
| 1 | Control Center → Save Clipboard: Copyd opens, you allow paste, and the clip is saved | Pending |
| 2 | Action button set to Save Clipboard and to Search Copyd | Pending |
| 3 | Shortcuts lists "Save Clipboard" and "Search Copyd" once each | Pending |
| 4 | Lock Screen circular "Save" and inline latest-clip widgets (redacted while locked) | Pending |
| 5 | Spotlight: search for a clip's text, tap it with Copyd closed, and it is copied | Pending |
| 6 | Spotlight never shows a secret, and a deleted clip disappears from results | Pending |
| 7 | A link copied on the Mac shows its title and image on the Mac card and the iPhone row | Pending |
| 8 | A magic-login or password-reset link is never opened by Copyd (no preview) | Pending |
| 9 | Code shows colors on the Mac card and in Quick Look. A color shows a large swatch with RGB | Pending |
| 10 | iOS 17 or 18 device, if available: the Lock Screen widgets work, and the controls are hidden | Pending |

## Known limits

- **Text clips:** only link (`.url`) clips get previews. A text clip that is a single URL does not.
- **Private hostnames:** a DNS name that resolves to a private address is still fetched. Only literal local and private hosts are skipped.
- **Unchanged clips in Spotlight:** an unchanged clip is skipped within a launch, but the first change after each launch reindexes it.
