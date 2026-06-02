#!/bin/bash
#
# Build a Developer ID-signed, notarized, stapled Workroom.app for distribution.
#
# One-time setup — store your notarization credentials in a keychain profile
# (an app-specific password from https://appleid.apple.com, NOT your Apple ID password):
#
#   xcrun notarytool store-credentials "workroom-notary" \
#       --apple-id "you@example.com" \
#       --team-id  B898J443L9 \
#       --password "abcd-efgh-ijkl-mnop"
#
# Then: macapp/Scripts/release.sh
set -euo pipefail

PROFILE="${NOTARY_PROFILE:-workroom-notary}"
MACAPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="${MACAPP_DIR}/WorkroomApp.xcodeproj"
BUILD="${MACAPP_DIR}/build/release"
APP="${BUILD}/Build/Products/Release/Workroom.app"
ZIP="${BUILD}/Workroom.zip"

export PATH="/usr/local/go/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

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

echo "==> Notarizing (profile: $PROFILE)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling + Gatekeeper assessment"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo "✅ Notarized + stapled: $APP"
echo "   Distributable zip: $ZIP (re-zip after stapling if you ship the zip)"
