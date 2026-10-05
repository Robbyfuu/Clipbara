#!/bin/bash
# Copyd Mac App Store build pipeline.
#
# Usage:
#   bash scripts/build-mas.sh            # archive + export signed .pkg (no upload)
#   UPLOAD=1 bash scripts/build-mas.sh   # archive + upload to App Store Connect
#
# Prerequisites (one-time):
#   - "Apple Distribution: MinSang Kim (5DH57J8HLC)" cert in login keychain
#   - "3rd Party Mac Developer Installer: MinSang Kim (5DH57J8HLC)" cert in login keychain
#   - Provisioning profile "Copyd Mac App Store" installed
#   - ASC API key at ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
#   - Issuer ID at ~/.appstoreconnect/issuer_id (single line)
#   - App record created in App Store Connect (required for upload only)
set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="/opt/homebrew/bin:$PATH"
# Some automation environments strip USER/LOGNAME; xcodegen needs them.
export USER="${USER:-$(id -un)}"
export LOGNAME="${LOGNAME:-$USER}"

TEAM_ID="5DH57J8HLC"
SCHEME="Copyd"
BUNDLE_ID="com.robbyfuu.copyd"
PROFILE_NAME="Copyd Mac App Store"
APP_CERT="Apple Distribution"
PKG_CERT="3rd Party Mac Developer Installer"
ASC_KEY_ID="${ASC_KEY_ID:-3687V5TUTK}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(cat "$HOME/.appstoreconnect/issuer_id" 2>/dev/null || true)}"

BUILD_DIR="build/mas"
ARCHIVE_PATH="$BUILD_DIR/Copyd.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

echo "==> Cleaning $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Generating Xcode project"
xcodegen generate

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Copyd/Info.plist)
BUILD_NUM=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Copyd/Info.plist)
echo "==> Version: $VERSION ($BUILD_NUM)"

# NOTE: manual signing (cert + provisioning profile) is configured on the
# Copyd target's Release config in project.yml. Do NOT pass signing
# overrides on the xcodebuild command line - they leak into SPM package
# targets (KeyboardShortcuts resource bundle) which reject provisioning profiles.
echo "==> Archiving $SCHEME (Release, manual signing via project.yml)"
xcodebuild archive \
  -project Copyd.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  | tail -5

PLIST_COMMON=$(cat <<EOF
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$APP_CERT</string>
  <key>installerSigningCertificate</key><string>$PKG_CERT</string>
  <key>provisioningProfiles</key>
  <dict><key>$BUNDLE_ID</key><string>$PROFILE_NAME</string></dict>
EOF
)

if [ "${UPLOAD:-0}" = "1" ]; then
  if [ -z "$ASC_ISSUER_ID" ]; then
    echo "ERROR: issuer ID not found (set ASC_ISSUER_ID or write ~/.appstoreconnect/issuer_id)" >&2
    exit 1
  fi
  echo "==> Uploading to App Store Connect"
  cat > "$BUILD_DIR/ExportOptions-upload.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$PLIST_COMMON
  <key>destination</key><string>upload</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions-upload.plist" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  echo "==> Upload submitted. Check App Store Connect > TestFlight/Builds for processing status."
else
  echo "==> Exporting signed .pkg (no upload)"
  cat > "$BUILD_DIR/ExportOptions-export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
$PLIST_COMMON
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions-export.plist" \
    -exportPath "$EXPORT_PATH"

  PKG=$(ls "$EXPORT_PATH"/*.pkg 2>/dev/null | head -1)
  echo "==> Exported: $PKG"
  echo "==> Verifying signatures"
  APP_IN_ARCHIVE="$ARCHIVE_PATH/Products/Applications/Copyd.app"
  codesign -dv --verbose=2 "$APP_IN_ARCHIVE" 2>&1 | grep -E "Authority=|TeamIdentifier=" | head -4
  pkgutil --check-signature "$PKG" | head -6
  echo "==> Entitlements:"
  codesign -d --entitlements :- "$APP_IN_ARCHIVE" 2>/dev/null | head -30
  echo ""
  echo "OK: $PKG ($VERSION build $BUILD_NUM)"
  echo "To upload: UPLOAD=1 bash scripts/build-mas.sh"
fi
