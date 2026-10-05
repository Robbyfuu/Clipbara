# Panel redesign and Copyd rename — visual check

Run on Mac A, 2026-10-02, against branch `feat/panel-redesign` at 69b93f3.

The app was built with `Copyd.xcodeproj`, scheme `Copyd`, and launched with `--args -CopydDebugOriginalAppVersion 1.0`.

| # | Check | Result |
|---|---|---|
| 1 | Panel spans the full screen width; history from before the rename is intact; top bar shows mark, History pill, +, centered search with ⌘F, "Synced · now", …, trash | pass |
| 2 | Holding ⌘ shows ⌘1…⌘9 badges; ⌘3 pastes the third visible card; after → past ten cards, the first visible badge is ⌘1 and ⌘1 pastes that card | pass |
| 3 | Typing `stag` and pressing ⌘1 immediately pastes nothing until the results show; then ⌘1 pastes the first result | pass |
| 4 | New pinboard: dragging a card over its tab highlights it in butter; ⌥⌘2 / ⌥⌘1 switch tabs | pass |
| 5 | Dark mode: ink shelf, dark cards, readable text | pass |
| 6 | Clicking "Synced · now" closes the panel and opens Settings in front | pass |
| 7 | The Copyd mark at the top-left of the panel renders whole | pass |
| 8 | `CopydTests`: 146 tests pass; the `Copyd` scheme builds | pass |
