# Copyd: Paste-style card headers, automatic pinboards, Markdown

- **Date:** 2026-10-06
- **Status:** approved by the user in chat on 2026-10-06. They authorized merging to `main` and installing while away.
- **Branch:** `feat/cards-smartboards-markdown`, created from `main` after round 1 (everywhere-previews) is merged.
- **Reference:** Paste's "Private by design" grid. Each card header takes its source app's color and shows the type, the relative time and a large app icon.

## 1. Card headers in the source app's style

### Mac card (`ClipboardCardView`)

- **Background:** the header fill is the app's dominant color.
- **Header text:**
  - Line 1, bold: the type, or the user's title if there is one.
  - Line 2: `<App name> · <relative time>`.
  - The text color is picked for contrast against the fill (§1 "Contrast").
- **Icon:** a 36 pt app icon on the right edge, partly clipped by the card corner, as in the reference.
- **Fallback.** With no source app, or the app unknown on this Mac, the header uses `Brand.butter` and the Copyd mark.
- **Secrets keep their masked body.** The header is unchanged, so it still shows the app.
- **Unchanged:** the pin badge, suggestion and multi-select states, the quick-paste numbers, and the footer.

### Dominant color

- `IconColor.dominant(rgba: [UInt8], width:, height:) -> RGB` is pure and tested.
- Algorithm:
  1. Downsample to 32×32.
  2. Ignore pixels with alpha < 128.
  3. Ignore near-white and near-black pixels (luma > 0.92 or < 0.08) when at least 20 % of pixels remain.
  4. Quantize to 4 bits per channel, take the most frequent bucket, and average its pixels.
- Cache the result per bundle id.

### Contrast

- `ContrastPicker.textColor(on: RGB) -> .light | .dark` uses WCAG relative luminance.
- Rule: use dark text when contrast(dark ink) ≥ contrast(white). It is pure and tested.

### iPhone

- **Row (`ClipRow`):**
  - A 28 pt app icon replaces the generic type glyph whenever an icon is known.
  - The subtitle reads `<App name> · <relative time>`.
  - The type label takes the app color when that color's contrast on the row background is at least 3:1. Otherwise it stays `Brand.ink2`.
- **Keyboard:** each card shows a 14 pt icon in a corner. The widget is unchanged.

### App identities sync from the Mac

- iOS can't read other apps' icons, so the Mac publishes them.
- **New SwiftData `@Model AppIdentity`.** It is additive and adds a new entity.

  | Field | Type |
  |---|---|
  | `bundleId` | `String`, unique by code |
  | `name` | `String` |
  | `iconPNG` | `Data`, 128×128 PNG, external storage |
  | `colorHex` | `String` |
  | `updatedAt` | `Date` |
  | `syncSystemFields` | `Data?` |

- **New CloudKit record type `AppIdentity`.** It lives in the existing `Clipboard` zone.
  - Record name: `app-` plus a SHA-256 hex of the bundle id.
  - Fields: encrypted `bundleId`, `name` and `colorHex`; `iconPNG` as an encrypted value, since it is under 256 KB.
  - Older app versions already skip unknown record types (`CloudSyncEngine` logs "Skipped record of unknown type"), so this is backward compatible.
- **Mac publish rule.**
  - When a clip is captured from a bundle id with no `AppIdentity`, or one with `updatedAt` older than 30 days, render the icon at 128 px, compute the color, and upsert the identity.
  - The tracker uploads it like any other local save.
  - Never create one for Copyd's own bundle id.
- **Pruning.** Identities are never deleted automatically. They are tiny, and they stay useful for clips on other devices.
- **Reading on iPhone and Mac.** Look up the identity by bundle id. On the Mac, the live `NSWorkspace` icon takes precedence and the synced one is the fallback. That fallback covers an app that exists only on another Mac.
- **Pending App Store prep:** deploy the `AppIdentity` record type to CloudKit Production (`CLAUDE.md`'s pending list).

## 2. Automatic pinboards

- **Smart boards are virtual filters, not `Pinboard` entities.** Nothing is copied or synced.
  - Each device classifies its own clips into local-only attributes.
  - Smart boards are read-only: no rename, delete, reorder or drag-in.
- **Type boards.** Use these exact names (en/es) and this order:

  | English | Spanish | Contents |
  |---|---|---|
  | Links | Enlaces | URL clips |
  | Code | Código | Detected by round 1's `CodeDetector` |
  | Addresses | Direcciones | NSDataDetector `.address` |
  | Phones & Emails | Teléfonos y correos | NSDataDetector `.phoneNumber`, or an email `.link` with `mailto` |
  | Images | Imágenes | Image clips |
  | Colors | Colores | Color clips |
  | Files | Archivos | File clips |

- **Topic boards (Apple Intelligence).** Use these exact names and this order:

  | English | Spanish |
  |---|---|
  | Work | Trabajo |
  | Shopping | Compras |
  | Travel | Viajes |
  | Finance | Finanzas |
  | Study | Estudio |
  | Social | Social |
  | Personal | Personal |

  - The model may also answer `other`. Those clips get no topic board.
  - The model gets text and link clips only: 300-character previews, with link titles when present.
  - Never send it secrets, images or files.
  - It runs on device through `FoundationModels`, only where it is available. That means macOS 26+ and iOS 26+ with Apple Intelligence enabled. The framework is weak-linked.
  - The model returns a `@Generable` enum.
- **Storage.** These additive local-only attributes on `ClipboardItem` are never mapped:

  | Attribute | Type | Meaning |
  |---|---|---|
  | `smartKinds` | `Int = 0` | Bitmask of type boards |
  | `smartKindsVersion` | `Int = 0` | Bump `SmartKinds.version` (= 1) to reclassify everything |
  | `topicRaw` | `String?` | |
  | `topicDone` | `Bool = false` | |

  - An edit resets all four.
- **Classification passes.**
  - **When:** on capture (Mac) and in a fill pass over the newest 1,000 clips. It runs in batches of 50 for types and 10 for topics, and is never in an extension.
  - **Threading:** the same structure as OCR, with a utility queue and one pass at a time. The write is a tracked pre-save, then a suppressed save.
  - **Topic failures:** a model failure leaves `topicDone == false`. `other` and unavailable both set `topicDone = true` with `topicRaw = nil`. When the model becomes available later, the version key resets these.
- **UI.**
  - **Mac nav bar:** smart boards come after the user's pinboards, each with a ✨ glyph. Only non-empty boards are shown.
    - ⌥⌘1–9 numbering keeps counting through them in display order.
    - Picking a card from a smart board works like any pick.
  - **iPhone Pinboards tab:** an "Automatic" / "Automáticos" section lists the non-empty boards with counts. Tapping one opens a list filtered like History.
  - **Keyboard:** the pinboards mode lists the type boards after the user's boards. The keyboard reads the attributes read-only.
- **Settings (Mac General and iOS).**

  | Setting (en / es) | Key | Default | Scope |
  |---|---|---|---|
  | "Automatic pinboards" / "Tableros automáticos" | `smartBoardsEnabled` | on | Turns off every smart board |
  | "Group by topic with Apple Intelligence" / "Agrupar por tema con Apple Intelligence" | `smartTopicsEnabled` | on | Topic boards only; shown only where the model is available |

  - On iOS both keys are stored in the App Group.

## 3. Markdown

- **Paste/Copy/Insert as → Markdown.** A new `TextTransform.markdown`, offered for `.richText` and `.html` clips.
  - `MarkdownConverter.markdown(fromHTML:)` is a pure converter for a tag subset: `h1`–`h6`, `p`, `br`, `b`/`strong`, `i`/`em`, `a`, `ul`/`ol`/`li` (nested), `code`, `pre`, `blockquote`. Unknown tags are dropped and their text kept. HTML entities are decoded.
  - `MarkdownConverter.markdown(from: NSAttributedString)` walks the attributes, for RTF:
    - bold and italic font traits;
    - `.link`;
    - `NSTextList` paragraph lists;
    - headings by font size: at least 1.6× the body is `#`, at least 1.3× is `##`, with the body size taken as the most common size.
    - RTF decoding runs off the main actor (`NSAttributedString(data:options:[.documentType: .rtf])`).
  - The keyboard gets this transform only when it can read the source data. Otherwise it is hidden.
- **Paste as → Formatted text** (`TextTransform.richText`). Offered when `MarkdownDetector.isMarkdown(text)`.
  - Converts with `AttributedString(markdown:)` using full Markdown parsing, then `NSAttributedString`.
  - Writes RTF plus plain text to the pasteboard.
  - Mac and iPhone app only. Never offered in the keyboard, which can only insert plain text.
- **Detection.** `MarkdownDetector.isMarkdown(_:) -> Bool` is pure. It needs at least two Markdown signals: `#` headings, `-`/`*`/`1.` list lines, `**bold**`, `[text](url)`, or fenced code. Prose with a single `*` or `#` is not Markdown.
- **Rendering.** Mac text cards, Quick Look and the iOS row render detected Markdown.
  - Headings are bold and slightly larger, list bullets are shown, and inline bold, italic, code and links are styled.
  - Each line goes through `AttributedString(markdown:, options: .inlineOnlyPreservingWhitespace)`, plus a per-line heading and list prefix.
  - Search highlighting stays on top.
  - Code rendering from round 1 takes precedence when `CodeDetector` also matches.

## 4. Testing

- **Unit tests:**
  - `IconColor` with solid, two-tone and transparent fixtures.
  - `ContrastPicker`.
  - `AppIdentity` mapper round-trip, plus record-name stability.
  - The publish rule: once per bundle, refresh after 30 days, never Copyd itself.
  - `SmartKinds` classification for each kind, and the version bump.
  - Topic plan selection: secrets, images and files skipped; retry on failure.
  - The mapper never sees the smart or topic fields.
  - An edit resets them.
  - `MarkdownConverter` for HTML and attributed-string fixtures.
  - `MarkdownDetector` positives and negatives.
  - The `TextTransform` applicability for the two new transforms.
  - A migration test that fetches the new attributes and the new entity.
- **Simulator:**
  - An iOS row with a synced identity shows the icon and app name. Seed an `AppIdentity` under a DEBUG argument.
  - The Automatic section lists seeded boards.
  - A Markdown clip renders formatted.
- **Mac:** build checks only for the agents. The user checks the headers visually after install.

## 5. Out of scope

- A grid layout for iPhone History.
- Custom topic lists.
- Smart boards on the widget.
- Markdown tables and images.
- Syncing classifications.
