# Copyd: text in images, edit and transform, secret handling

- **Date:** 2026-10-04
- **Status:** draft. The user picked these 3 features. Design pending approval.
- **Branch:** `feat/clip-tools`, stacked on `feat/smart-suggestions`.

## 1. Text in images (on-device OCR)

**Goal:** find a screenshot or photo by the text in it, and copy just that text.

- **Engine:** Vision `VNRecognizeTextRequest`.
  - `.accurate`, with `automaticallyDetectsLanguage`, plus `recognitionLanguages` `["es", "en"]` as the hint.
  - Runs on device only, with no network.
  - Works on macOS 14+ and iOS 17+.
- **Input:** the image's `rawData`, downsampled to at most 2048 px with ImageIO, never fully decoded. Never run OCR in the keyboard or the widget.
- **When:**
  - On the Mac, right after an image clip is captured, in a background task at utility priority.
  - On every device, a low-priority pass fills clips that still lack the text. It covers the last 300 image clips and runs in batches of 10.
  - On the iPhone, the pass runs only while the app is open.
- **Storage:**
  - `ocrText: String?`, local only and not synced, so each device computes its own. This adds no schema change in CloudKit.
  - `ocrDone: Bool` marks that recognition already ran, so empty results aren't retried.
  - Both are additive SwiftData attributes.
- **Search:** the search in the Mac panel and in the iPhone History also matches `ocrText`.
- **UI:**
  - Image cards with recognized text show a small "Aa" badge.
  - **Copy text** / "Copiar texto" puts the recognized text on the pasteboard:
    - On the Mac, it is in the card's context menu, with the shortcut ⌥Return on the selected card.
    - On the iPhone, it is on the long-press menu.
  - In Mac Quick Look, the recognized text appears under the image and can be selected.
- **Privacy:** recognized text never leaves the device and is never sent to the suggestions model.

## 2. Edit and transform

**Paste or copy as…** applies a transform at paste time and leaves the clip unchanged. Transforms:

| Transform | Spanish |
|---|---|
| Plain text | Texto sin formato |
| UPPERCASE | MAYÚSCULAS |
| lowercase | minúsculas |
| Title Case | Tipo Título |
| Trim whitespace | Quitar espacios sobrantes (each line, plus blank lines at the ends) |
| Clean link | Limpiar link (removes `utm_*`, `fbclid`, `gclid`, `mc_eid`, `igshid`, `si`, `ref_src`, `spm` and `_hs*` parameters; keeps the rest) |
| Pretty JSON | JSON legible |
| Compact JSON | JSON compacto |

- Transforms only appear when they apply. For example, Clean link appears for URLs or text that contains a URL, and the JSON transforms only for valid JSON.
- **Where:**
  - **Mac:** the card context menu "Paste as…" / "Pegar como…", plus the shortcut ⇧⌥Return, which opens the transform menu for the selected card. The paste goes through the normal pick funnel: direct paste and the paste history are recorded.
  - **iPhone:** long-press a row and choose "Copy as…" / "Copiar como…". The keyboard gets the same menu through a long-press on a card, inserting the transformed text.
- **Edit:**
  - **Mac:** ⌘E, or "Edit…" / "Editar…" in the context menu, opens a small "Edit clip" window with a text editor, Save and Cancel. The window is a normal Copyd window, so Copyd activates.
  - **iPhone:** the long-press menu shows an "Edit" sheet.
  - Saving replaces the clip's text, stores it as plain text, updates `contentHash`, and syncs to the other devices. It applies to text-like clips only.
- **Logic:** `TextTransform` (`enum` plus `apply(to:) -> String?` and `applicable(to:)`) lives in `Shared/` and is unit-tested.

## 3. Secrets: detect, keep local, auto-delete

- **Detection:** `SecretDetector.kind(of:) -> SecretKind?` is pure and tested. It recognizes:
  - **API keys and tokens:**

    | Type | Pattern |
    |---|---|
    | AWS access key | `AKIA…` |
    | GitHub | `ghp_`, `gho_`, `github_pat_` |
    | Stripe | `sk_live_`, `rk_live_` |
    | Slack | `xox[abprs]-` |
    | OpenAI | `sk-…`, at least 32 characters |
    | Anthropic | `sk-ant-` |
    | Google API | `AIza…`, 39 characters |
    | JWT | `eyJ….eyJ….…` |
    | Private key | `-----BEGIN … PRIVATE KEY-----` |

  - **Card numbers:** 13–19 digits, with or without spaces or dashes, that pass the Luhn check.
  - **No generic entropy guessing.** It would match too many normal strings.
- **On capture:** Mac capture, iPhone capture, Share, Save Text, and the keyboard inbox. If the detector matches:
  - The clip is stored with `isSensitive = true`. It is local only: the sync tracker and the mapper never upload it, and remote devices never see it.
  - The preview is masked, for example "API key •••• 3f9a" / "Clave de API •••• 3f9a" or "Card •••• 4242" / "Tarjeta •••• 4242", with a lock badge. Pasting it works normally.
  - It is excluded from:
    - suggestions and the model prompt
    - the widget
    - the Live Activity
    - arrival notices
    - the keyboard feed
    - search snippets (the masked label is still searchable)
  - It is deleted automatically after the chosen time. Settings offers 1, 5 (default), 15 or 60 minutes, or Never. A sweep runs on a timer while the app runs, and again at launch.
- **Setting:** "Protect secrets" / "Proteger secretos", on by default.
- **Already-synced clips:** detection runs only on new captures. A one-time pass over local history can mark old clips as sensitive and offer to delete them, but that is out of scope for now.

## 4. Testing

- **Unit tests:**
  - `TextTransform`: every transform, applicability, unicode, invalid JSON.
  - `SecretDetector`: each pattern positive and negative, Luhn, no false positives on normal URLs, UUIDs or hex hashes.
  - The auto-delete sweep, with a fake clock.
  - The tracker and mapper never upload `isSensitive` clips.
  - The OCR pipeline as a pure parts test: downsample size, batch selection, the `ocrDone` marking.
- **Devices:**
  - Screenshot a page with text, then search for a word from it in the Mac panel and in the iPhone History.
  - Paste a URL with `utm_` parameters as "Clean link".
  - Copy a fake Stripe key: the clip shows masked, doesn't sync, and disappears after 1 minute with that setting.

## 5. Out of scope

- OCR of PDFs and file clips.
- Translation.
- Editing images.
- Rewriting the clip with AI.
- Scanning existing history for secrets.
