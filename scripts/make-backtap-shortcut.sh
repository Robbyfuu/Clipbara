#!/bin/bash
# Rebuilds the signed shortcuts that the iOS Back Tap guide shares (Settings > Quick setup).
# One action: Copyd's SaveClipboardIntent. Shortcuts names an imported shortcut after its file, so there is one
# file per language; the app picks it by the localized "Save to Copyd" string.
# Needs this Mac signed in to iCloud: `shortcuts sign` refuses otherwise, and iOS rejects unsigned imports.
# Usage: [MODE=anyone] bash scripts/make-backtap-shortcut.sh
set -euo pipefail

# Re-sign with MODE=anyone before any App Store or public build; people-who-know-me files only import on the
# signer's own devices and contacts.
MODE="${MODE:-people-who-know-me}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/CopydiOS/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
UNSIGNED="$TMP/unsigned.shortcut"

# AppIntentIdentifier is the intent's Swift type name; the action identifier is "<bundle id>.<type name>".
# Icon: glyph 61440 on Shortcuts' yellow (0xFFD426FF), the closest palette color to Copyd's butter.
cat > "$UNSIGNED" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WFWorkflowActions</key>
	<array>
		<dict>
			<key>WFWorkflowActionIdentifier</key>
			<string>com.robbyfuu.copyd.SaveClipboardIntent</string>
			<key>WFWorkflowActionParameters</key>
			<dict>
				<key>AppIntentDescriptor</key>
				<dict>
					<key>AppIntentIdentifier</key>
					<string>SaveClipboardIntent</string>
					<key>BundleIdentifier</key>
					<string>com.robbyfuu.copyd</string>
					<key>Name</key>
					<string>Copyd</string>
					<key>TeamIdentifier</key>
					<string>TQC76W2BKK</string>
				</dict>
				<key>UUID</key>
				<string>6C0D3B1E-5A7F-4E2B-9C41-0B7AC0D1C0DE</string>
			</dict>
		</dict>
	</array>
	<key>WFWorkflowClientVersion</key>
	<string>5037.0.17</string>
	<key>WFWorkflowMinimumClientVersion</key>
	<integer>900</integer>
	<key>WFWorkflowMinimumClientVersionString</key>
	<string>900</string>
	<key>WFWorkflowIcon</key>
	<dict>
		<key>WFWorkflowIconGlyphNumber</key>
		<integer>61440</integer>
		<key>WFWorkflowIconStartColor</key>
		<integer>4292093695</integer>
	</dict>
	<key>WFWorkflowImportQuestions</key>
	<array/>
	<key>WFWorkflowInputContentItemClasses</key>
	<array>
		<string>WFAppContentItem</string>
		<string>WFAppStoreAppContentItem</string>
		<string>WFArticleContentItem</string>
		<string>WFContactContentItem</string>
		<string>WFDateContentItem</string>
		<string>WFEmailAddressContentItem</string>
		<string>WFFolderContentItem</string>
		<string>WFGenericFileContentItem</string>
		<string>WFImageContentItem</string>
		<string>WFiTunesProductContentItem</string>
		<string>WFLocationContentItem</string>
		<string>WFDCMapsLinkContentItem</string>
		<string>WFAVAssetContentItem</string>
		<string>WFPDFContentItem</string>
		<string>WFPhoneNumberContentItem</string>
		<string>WFRichTextContentItem</string>
		<string>WFSafariWebPageContentItem</string>
		<string>WFStringContentItem</string>
		<string>WFURLContentItem</string>
	</array>
	<key>WFWorkflowTypes</key>
	<array/>
</dict>
</plist>
PLIST

plutil -lint "$UNSIGNED"
for name in "Save to Copyd" "Guardar en Copyd"; do
    echo "==> Signing $name.shortcut ($MODE)"
    shortcuts sign --mode "$MODE" --input "$UNSIGNED" --output "$OUT/$name.shortcut"
done
ls -l "$OUT"/*.shortcut
