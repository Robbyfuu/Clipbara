# App-colored cards, automatic pinboards, Markdown: device check

- **Date:** 2026-10-06
- **Spec:** `docs/superpowers/specs/2026-10-06-cards-smartboards-markdown-design.md` §4
- **Automated checks:** 730 unit tests pass. The Mac and iOS simulator builds pass in both Debug and Release. FoundationModels is weak-linked in both apps.
- **iOS 27 simulator:**
  - A row shows its synced app icon and the app name.
  - The "Automáticos" section lists type and topic boards with counts, classified by the real on-device model.
  - A Markdown row renders formatted.
- **Install order:** install the iPhone before the Mac, so the iPhone receives the Mac's first app icons.

## Results

| # | Check | Result |
|---|---|---|
| 1 | Mac card headers take each app's color and icon (Safari, Notes, Xcode, Terminal), and the text stays readable in light and dark | Pending |
| 2 | The iPhone row shows the source app's icon and name for clips copied on the Mac | Pending |
| 3 | The Mac nav bar shows ✨ boards after your pinboards. A new link appears in "Enlaces" without reopening the panel | Pending |
| 4 | Topic boards (Trabajo, Compras, Viajes…) fill in over a few minutes, and the panel stays responsive | Pending |
| 5 | A secret, such as a fake `sk_live_` key, never appears in any automatic board | Pending |
| 6 | Copy a Google Docs paragraph with bold text, then "Pegar como → Markdown": only the real bold becomes `**…**` | Pending |
| 7 | Copy Markdown text, then "Pegar como → Texto con formato" into Notes or Pages: it pastes formatted | Pending |
| 8 | Markdown clips render formatted on the Mac card and the iPhone row. Links don't open on click | Pending |
| 9 | The keyboard shows type boards and opens without errors after the app has been opened once | Pending |

## Known limits

- **Late icons.** A device updated after the Mac published an app's icon gets it within 7 days.
- **Topic window.** Topics cover the newest 300 clips on iPhone and 1000 on the Mac. Links wait up to 1 day for their title before being sorted.
- **Unsupported languages.** Devices whose language the on-device model doesn't support get no topic boards.
