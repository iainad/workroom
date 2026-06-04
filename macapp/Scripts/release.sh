#!/bin/bash
#
# Build a Developer ID-signed, notarized, stapled Workroom.dmg installer for distribution
# (the app inside is notarized + stapled too). Requires `create-dmg` (brew install create-dmg).
#
# Notarization auth, either:
#   - Local: store credentials in a keychain profile (an app-specific password from
#     https://appleid.apple.com, NOT your Apple ID password), then run the script:
#
#       xcrun notarytool store-credentials "workroom-notary" \
#           --apple-id "you@example.com" \
#           --team-id  B898J443L9 \
#           --password "abcd-efgh-ijkl-mnop"
#
#   - CI / API key: set NOTARY_KEY_PATH (App Store Connect .p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID.
#
# Then: macapp/Scripts/release.sh
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-workroom-notary}"
MACAPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="${MACAPP_DIR}/WorkroomApp.xcodeproj"
BUILD="${MACAPP_DIR}/build/release"
APP="${BUILD}/Build/Products/Release/Workroom.app"
ZIP="${BUILD}/Workroom.zip"
DMG="${BUILD}/Workroom.dmg"

export PATH="/usr/local/go/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

# Submit a container (.zip/.dmg) to Apple's notary service and wait. Uses an App Store Connect
# API key when NOTARY_KEY_PATH is set (CI: --key/--key-id/--issuer), else a local keychain
# profile (NOTARY_PROFILE, default "workroom-notary"). See the store-credentials note above.
notarize() {
  if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    echo "    (App Store Connect API key)"
    xcrun notarytool submit "$1" \
      --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
  else
    echo "    (keychain profile: $PROFILE)"
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
  fi
}

if [ ! -d "$PROJ" ]; then
  echo "Generating Xcode project…"
  ( cd "$MACAPP_DIR" && xcodegen generate )
fi

echo "==> Building Release (Developer ID, hardened runtime, timestamp)"
xcodebuild -project "$PROJ" -scheme WorkroomApp -configuration Release \
  -derivedDataPath "$BUILD" \
  -clonedSourcePackagesDirPath "$BUILD/SourcePackages" \
  build

echo "==> Verifying signatures"
codesign --verify --strict --verbose=2 "$APP"
echo "--- embedded helper ---"
codesign -dv --verbose=4 "$APP/Contents/Resources/workroom" 2>&1 \
  | grep -iE "Authority|TeamIdentifier|flags|Timestamp" || true

echo "==> Notarizing app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"

echo "==> Stapling app + Gatekeeper assessment"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP" || true

# Package the notarized + stapled app into a drag-to-Applications DMG, sign it with the same
# Developer ID, then notarize + staple the DMG so it opens with no Gatekeeper prompt. The
# stapled app lives inside a stapled DMG, so first launch is clean even offline.
echo "==> Building DMG installer"
command -v create-dmg >/dev/null 2>&1 \
  || { echo "error: 'create-dmg' not found on PATH. Install it (brew install create-dmg)." >&2; exit 1; }
STAGE="${BUILD}/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
create-dmg \
  --volname "Workroom" \
  --window-size 660 400 --icon-size 100 \
  --icon "Workroom.app" 160 185 \
  --app-drop-link 500 185 \
  --hide-extension "Workroom.app" \
  --codesign "Developer ID Application" \
  "$DMG" "$STAGE"

echo "==> Notarizing + stapling DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" || true

echo "✅ Notarized + stapled installer: $DMG"
