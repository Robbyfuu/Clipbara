# Copyd: system integration on iPhone and rich previews

- **Date:** 2026-10-05
- **Status:** design approved in chat by the user, 2026-10-05.
- **Branch:** `feat/everywhere-previews`, created from `main` at 4a92c79.
- **Scope:**
  - System integration on iPhone and iPad: Control Center, the Action button, Lock Screen widgets and Spotlight.
  - Rich previews on the Mac, iPhone and keyboard: link previews, code highlighting and larger color swatches.

## 1. Controls (Control Center and the Action button)

- These are iOS 18+ `ControlWidget`s in the widget extension. They are gated with `if #available(iOS 18, *)` inside the `WidgetBundle`. On iOS 17 they don't exist, and everything else works as before.
- **Save Clipboard / "Guardar portapapeles"** opens Copyd, which saves the pasteboard through the existing save path (`AppModel.pendingRoute = .saveClipboard`). iOS only lets the foreground app read the pasteboard, so the app has to open.
- **Search Copyd / "Buscar en Copyd"** opens Copyd on History with the search field focused. This needs a new `QuickRoute.search` destination if the existing search route doesn't already focus the field.
- **The user can assign either control to the Action button.** This needs no extra code.
- **Rule: never expose "save clipboard" as a URL route.** A web page could otherwise make Copyd read the pasteboard. The controls run `AppIntent`s that open the app (`openAppWhenRun`, `OpenIntent` or the iOS 18 equivalent) and hand over the route in process.
  - The intent must be visible to the widget extension, but `AppModel` is app-only. The implementer chooses the mechanism, for example:
    - a shared intent type whose `perform` is compiled only into the app, or
    - an `OpenIntent`/`AppIntent` that lives in both targets under the `WIDGET_EXTENSION` compilation condition.
  - Whatever the mechanism, it must be verified in the simulator: tapping the control opens the app and triggers the route.

## 2. Lock Screen widgets

The existing `RecentClipsWidget` keeps `.accessoryRectangular`. Add:

- **Circular widget "Save" / "Guardar"** (`.accessoryCircular`).
  - It shows a `Button(intent:)` that runs the same save-clipboard intent. iOS asks to unlock before opening the app.
  - It uses the Copyd mark or a clipboard symbol, and works in the vibrant rendering mode.
- **Inline widget, latest clip** (`.accessoryInline`).
  - It shows one line with the latest clip's preview, masked for secrets and hidden for secrets in the widget feed, as today.
  - It is `privacySensitive()`, so it is redacted while the iPhone is locked, like the current widget.

## 3. Spotlight (iPhone and iPad)

- **Scope (user choice): everything except secrets.**

  | Clip type | Indexed | Title |
  |---|---|---|
  | Text | Yes | First line, up to 80 characters |
  | Link | Yes | Link title (§4) or URL |
  | Image with OCR text | Yes | "Image" / "Imagen", plus the first OCR line |
  | File | Yes, by file name | File name |

  - **Never indexed:** `isSensitive` clips, images without OCR text, colors, unknown types and empty text.
  - **Description:** up to 300 characters.
  - **Thumbnail:** `thumbnailData` for images, `linkImageData` for links.
- **Engine:** CoreSpotlight `CSSearchableIndex.default()`, with domain identifier `clips` and unique identifier = clip UUID string. App target only, never in an extension.
- **Pure unit:** `SpotlightPlan`.
  - `record(for:) -> SpotlightRecord?` returns nil for anything that must not be indexed.
  - `changes(inserted:updated:deleted:)` returns the ids to upsert and the ids to delete.
  - An update that turns a clip into a secret, or removes its OCR text, becomes a delete.
- **Triggers:**
  - **Every main-context save:** `ModelContext.didSave`. This covers local saves, sync-applied changes, the secret sweep, history-limit cleanup and the Share inbox drain.
  - **Full rebuild:** on first launch with a new index version (`spotlightIndexVersion = 1`), and when the setting is turned back on.
  - **Local mirror wiped** (account change or zone deleted): delete everything.
- **Tapping a result** continues `CSSearchableItemActionType` and routes to `QuickRoute.copy(uuid)`. That copies the clip and shows the existing "Copied" toast.
- **Setting:** "Show in Spotlight" / "Mostrar en Spotlight", on by default, in iOS Settings. Turning it off calls `deleteSearchableItems(withDomainIdentifiers: ["clips"])`.

## 4. Link previews (Mac and iPhone app)

- **Fetch.** `LinkPreviewFetcher` runs in the Mac app and the iPhone app, never in an extension.
  - It uses `LPMetadataProvider` with a 10 s timeout, and only for `http`/`https` URLs.
  - It reads the title plus `imageProvider`, falling back to `iconProvider`.
  - The image is downsampled with ImageIO to at most 640 px and stored as JPEG at quality 0.7.
- **When:**
  - Right after a link clip is captured.
  - In a fill pass that covers the newest 300 link clips in batches of 5. On the Mac it runs at launch and on remote changes; on iOS, only while the app is in the foreground and on remote changes.
  - Never for `isSensitive` clips.
- **Storage:** additive local-only SwiftData attributes that are never mapped to CloudKit. Each device fetches its own previews.
  - `linkTitle: String?`
  - `linkImageData: Data?` (external storage)
  - `linkPreviewDone: Bool = false`
- **Failures:**
  - Offline or timeout leaves `linkPreviewDone == false`, so the next fill retries.
  - A definitive failure (no metadata, HTTP error) sets `linkPreviewDone = true` with nil fields, so dead links are not refetched.
  - A failed id is kept in a per-pass set, so it is never retried within the same pass.
- **Edits.** When an edit changes `textContent`, the preview fields are cleared.
- **Setting:** "Link previews" / "Vistas previas de links", on by default, on the Mac (General) and on iOS. When off, Copyd fetches nothing and the cards show the current domain-and-path layout.
- **Mac sandbox.** Add `com.apple.security.network.client` to `Copyd.entitlements`.
- **Display:**
  - **Mac card** (`LinkCardContent`): the image on top (fill, clipped), then the title (2 lines) and the domain. Without a preview, the current layout. Quick Look shows the image and the title.
  - **iOS row:** a link thumbnail and the title, with the domain as the subtitle.
  - **Keyboard and widget:** the title replaces the URL text in the preview. Never the image, to save memory.
- **Search** also matches `linkTitle`, in both the Mac panel and iOS History.

## 5. Code highlighting

- **Pure units:**
  - `CodeDetector.isCode(_ text: String) -> Bool`. It is a heuristic over the first 2 KB that counts braces, semicolons at line ends, indentation, keywords, operators and a shebang. JSON counts as code. Prose, URLs and lists must not.
  - `SyntaxHighlighter.tokens(in text: String, limit: 2048) -> [CodeToken]`. A token is a range plus a kind: `keyword`, `string`, `comment` or `number`. It is language-agnostic:
    - comments: `//`, `#`, `/* */`, `--`
    - strings: single, double and backtick quotes
    - keywords: one combined set for Swift, JS/TS, Python, Go, Rust, SQL and shell
- **Colors:** new dynamic Brand tokens `codeKeyword`, `codeString`, `codeComment` and `codeNumber`, light and dark.
- **Where:** the Mac `TextCardContent` (monospaced when the text is code), Quick Look, and the iOS row preview.
- **Search highlight** stays on top of the code colors.
- **Performance:** tokens are cached by `contentHash`, never recomputed on every `body` evaluation for every card.

## 6. Color swatches

- **Mac `ColorCardContent`:** a large swatch filling the card, with HEX and RGB below.
- **iOS row:** a larger swatch, 44 pt, with HEX as the title and RGB as the subtitle.

## 7. Localization

Every new string has `en` and `es` in the right catalog: Mac, iOS, keyboard and widget. Neutral Latin American Spanish, using "Configuración".

## 8. Testing

**Unit tests:**
- `SpotlightPlan`: each type in and out; secret and OCR transitions become deletes.
- `CodeDetector`: positives and negatives.
- `SyntaxHighlighter`: each kind, nested quotes, unterminated strings, the 2 KB limit.
- `LinkPreviewPlan`: batch selection, window, skipping secrets and non-http, done versus retry.
- The mapper never sees the link preview fields.
- An edit clears the preview fields.
- The migration test fetches the new attributes with predicates.

**Simulator:**
- The controls appear in Control Center and open the app on the right route.
- A seeded clip appears in Spotlight, and tapping it copies the clip.
- The circular and inline Lock Screen widgets render.
- A link card shows its title and image.
- A code clip shows colors.

**Device (user):**
- Save from Control Center and from the Action button.
- Find and copy a clip from Spotlight.
- A link preview appears on the Mac and on the iPhone.
- Code colors appear on the Mac card.

## 9. Out of scope

- Spotlight on the Mac, where the panel search already covers it.
- Syncing link previews.
- Controls on iOS 17.
- Link images in the keyboard.
- Language-specific grammars for highlighting.
- AI actions and snippets (possible next round).
