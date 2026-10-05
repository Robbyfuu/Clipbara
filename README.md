<p align="center">
  <img src="Copyd/Resources/Assets.xcassets/AppIcon.appiconset/256.png" width="128" height="128" alt="Copyd icon">
</p>

<h1 align="center">Copyd</h1>

<p align="center">
  A clipboard manager for macOS. Everything you copy stays on your Mac.
</p>

<p align="center">
  English | <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Robbyfuu/Clipbara?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue?style=flat-square" alt="macOS 14 or later">
</p>

Copyd keeps a history of what you copy. Press `⌘ ⇧ V` and a panel slides up at the bottom of the screen without pulling focus from the app you are in. Click a clip once and it is pasted into that app, once you allow Copyd in Accessibility. Until then, press <kbd>⌘</kbd> <kbd>V</kbd> yourself.

Copyd is a fork of [Clipbara](https://github.com/mobrava/Clipbara) by mobrava, licensed under GPL-3.0.

It runs on macOS 14 Sonoma or later.

## Install

### Build from source

Requires macOS 14 or later, Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/Robbyfuu/Clipbara.git ~/Code/Copyd && cd ~/Code/Copyd
brew install xcodegen
xcodegen generate
xcodebuild -project Copyd.xcodeproj -scheme Copyd -configuration Debug -derivedDataPath DerivedData -allowProvisioningUpdates build
open -n "$PWD/DerivedData/Build/Products/Debug/Copyd.app"
```

You can also open `Copyd.xcodeproj` and run the `Copyd` scheme with <kbd>⌘</kbd> <kbd>R</kbd>. The app is Swift 6 with strict concurrency on, SwiftUI hosted inside an AppKit `NSPanel`, and SwiftData for storage. Global shortcuts come from [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts).

### Mac App Store

App Store build coming.

## Usage

1. Copy anything with <kbd>⌘</kbd> <kbd>C</kbd> as usual.
2. Press <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>V</kbd> to open the history panel.
3. Type to search, or move between clips with <kbd>←</kbd> and <kbd>→</kbd>.
4. Click a clip once, or press <kbd>Return</kbd>. The panel closes and the clip is pasted into the app you were using once Accessibility is allowed. Otherwise press <kbd>⌘</kbd> <kbd>V</kbd>.

Inside the panel:

- <kbd>Space</kbd> opens and closes Quick Look for the selected clip
- <kbd>Esc</kbd> clears the search, steps back, or closes the panel
- <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>⌫</kbd> clears unpinned history
- Holding <kbd>⇧</kbd> while pasting flips plain-text pasting for that one paste
- Right-clicking a clip lets you rename it, add it to a Pinboard, or delete it

Both global shortcuts and the Quick Look key can be changed in **Settings > Shortcuts**.

## Features

- Text, rich text, HTML, images, links, files, and colors
- Search by content, title, or source app, with filters for type and date
- Pinboards for the clips you keep reusing
- Quick Look preview without leaving the panel
- Paste as plain text, always or per paste
- Excluded apps, so a password manager never reaches the history
- History limit, appearance, and launch at login
- JSON export and import for moving between machines or builds

## Privacy

History is stored on your Mac with SwiftData and stays there. No account, no server, no analytics.

Capture, search, preview, and paste all work offline. Copyd ships without an updater.

Add a password manager, or any other app, under **Settings > Exclusions** and nothing copied from it is recorded.

## FAQ

### How does Copyd paste into my app, and why does it need Accessibility?

When you pick a clip, Copyd puts it on the clipboard, closes the panel, and presses <kbd>⌘</kbd> <kbd>V</kbd> for you in the app you were using. Sending that keystroke to another app needs the Accessibility permission. Copyd asks for it once, the first time you pick a clip. Until you allow Copyd in **System Settings > Privacy & Security > Accessibility**, the clip still goes to your clipboard and you press <kbd>⌘</kbd> <kbd>V</kbd> yourself. Copyd only sends that one <kbd>⌘</kbd> <kbd>V</kbd>, right after a pick.

If direct paste stops working after an update, remove Copyd from **Accessibility** and add it again.

To keep pasting by hand, turn off **Settings > General > Paste directly into the app**.

Input Monitoring is a separate permission. Copyd asks for it only the first time you start Paste Stack. Paste Stack watches for <kbd>⌘</kbd> <kbd>V</kbd> so it can put the next clip on the clipboard, and it stops watching when the stack ends. Nothing else in Copyd needs it.

### The shortcut does not open the panel

Another app may already hold <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>V</kbd>. Record a different combination in **Settings > Shortcuts**.

### Images do not paste in my terminal

Picking an image clip writes it to the clipboard and sends <kbd>⌘</kbd> <kbd>V</kbd>, so a terminal receives the file URL of a temporary PNG, not image data. Programs that attach a clipboard image with <kbd>Control</kbd> <kbd>V</kbd>, such as Codex CLI, still need that key after the pick: pick the image, go back to the program without copying anything else, then press <kbd>Control</kbd> <kbd>V</kbd>.

### Where does the history live, and how do I remove it?

Copyd is sandboxed, so it stores the history in `~/Library/Containers/com.robbyfuu.copyd`. Deleting that folder deletes the history. To uninstall, drag the app to the Trash.

### Can I import my Clipbara history?

Yes. Export a JSON backup from Clipbara with **Settings > General > Backup > Export**, then use **Import** in Copyd. Existing clips are kept and duplicates are skipped.

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers the CLA that the dual licensing requires, and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) applies.

## License

Copyd is a fork of [Clipbara](https://github.com/mobrava/Clipbara) by mobrava, licensed under GPL-3.0. See [LICENSE](LICENSE).
