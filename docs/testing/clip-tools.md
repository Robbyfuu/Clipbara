# Clip tools: device check

- **Date:** 2026-10-05
- **Device:** iPhone 17 Pro Max with iOS 27, running a signed Debug build. CloudKit uses the Development environment.
- **Mac:** Debug build from `feat/clip-tools`, signed in to the same iCloud account.
- **Spec:** `docs/superpowers/specs/2026-10-04-clip-tools-design.md` §4.
- **Automated:** 502 unit tests pass. The Mac build and the iOS simulator build succeed. A simulator screenshot shows History search finding a seeded image by its text.

## Results

| # | Check | Result |
|---|---|---|
| 1 | Copy a fake Stripe key (`sk_live_` + 24 characters) on the Mac. The card shows "API key •••• xxxx" with a lock badge. | Pending |
| 2 | The same key never appears on the iPhone. | Pending |
| 3 | With "Delete secrets after" set to 1 minute, the key disappears. Pin another key: it stays. | Pending |
| 4 | Quick Look on a secret shows it masked until you press Show. | Pending |
| 5 | Copy an iPhone IMEI (`356938035643809`). It stays a normal clip. | Pending |
| 6 | Paste a link with `utm_` parameters using "Paste as…" → "Clean link" (⇧⌥Return). | Pending |
| 7 | Edit a clip with ⌘E. The change reaches the iPhone. | Pending |
| 8 | On the iPhone, long-press a row and use "Copy as…" → UPPERCASE. In the keyboard, long-press a card and use "Insert as…". | Pending |
| 9 | Screenshot a page with text. A word from it finds the image in the Mac panel and in iPhone History, and the card shows "Aa". | Pending |
| 10 | Use "Paste text" (⌥Return) on the Mac and "Copy text" on the iPhone. | Pending |

## Known limits

- **First OCR is slow.** The first text recognition after launch takes 20–60 s while Vision loads.
- **Secrets are detected only as a whole copy.** Detection fires when the copy is just the key, a `NAME=key` or `.env` line, a `Bearer` header, or a key in code. A key inside a sentence is not detected.
- **Images are never secrets.** Their recognized text is not scanned for secrets.
- **The keyboard offers "Insert as…" on a secret clipboard card.** The insert goes through the text proxy, not the pasteboard. This is parked.
