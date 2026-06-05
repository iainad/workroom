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

# Run `xcrun notarytool <subcommand> …` with whichever auth is configured: an App Store
# Connect API key when NOTARY_KEY_PATH is set (CI: --key/--key-id/--issuer), else a local
# keychain profile (NOTARY_PROFILE, default "workroom-notary"; see the store-credentials note).
notarytool_auth() {
  if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    xcrun notarytool "$@" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
  else
    xcrun notarytool "$@" --keychain-profile "$PROFILE"
  fi
}

# Submit a container (.zip/.dmg) and wait. NOTE: `notarytool submit --wait` exits 0 even when
# the result is Invalid, so we parse the final status ourselves; on anything but Accepted we
# dump Apple's per-file notary log (which states exactly what was rejected) and abort — never
# proceed to staple a ticket that was never issued.
notarize() {
  local out id status
  out="$(notarytool_auth submit "$1" --wait 2>&1)" || true
  echo "$out"
  id="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*id: \(.*\)$/\1/p' | head -1)"
  status="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*status: \(.*\)$/\1/p' | head -1)"
  if [ "$status" != "Accepted" ]; then
    echo "error: notarization returned '${status:-unknown}' for $(basename "$1")." >&2
    if [ -n "$id" ]; then
      echo "--- notary log ($id) ---" >&2
      notarytool_auth log "$id" >&2 || true
    fi
    exit 1
  fi
}

if [ ! -d "$PROJ" ]; then
  echo "Generating Xcode project…"
  ( cd "$MACAPP_DIR" && xcodegen generate )
fi

# Version for this build. CI passes the exact tag via $VERSION; locally we fall back to the
# latest tag. CFBundleVersion is the commit count — monotonic, so Sparkle always treats a newer
# release as an upgrade. Both values feed the appcast item (see Scripts/appcast.sh).
RAW_VERSION="${VERSION:-$(git -C "$MACAPP_DIR/.." describe --tags --always 2>/dev/null || echo 0.0.0)}"
SHORT_VERSION="${RAW_VERSION#v}"
BUILD_NUMBER="$(git -C "$MACAPP_DIR/.." rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Building Release $SHORT_VERSION ($BUILD_NUMBER) (Developer ID, hardened runtime, timestamp)"
xcodebuild -project "$PROJ" -scheme WorkroomApp -configuration Release \
  -derivedDataPath "$BUILD" \
  -clonedSourcePackagesDirPath "$BUILD/SourcePackages" \
  MARKETING_VERSION="$SHORT_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
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

# EdDSA-sign the DMG for Sparkle and record the fields the appcast needs (Scripts/appcast.sh
# turns these into a feed item). CI passes the private key via $SPARKLE_PRIVATE_KEY; locally
# sign_update falls back to the key `generate_keys` stored in your login keychain. The EdDSA
# `sign_update` ships in the Sparkle SPM package's artifacts (not the deprecated old_dsa_scripts).
SIGN_UPDATE="$(find "$BUILD/SourcePackages" -type f -name sign_update -not -path '*/old_dsa_scripts/*' 2>/dev/null | head -1 || true)"
SIG_ATTRS=""
if [ -z "$SIGN_UPDATE" ]; then
  echo "note: Sparkle's sign_update not found under SourcePackages; skipping appcast signing." >&2
elif [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "==> EdDSA-signing the DMG for Sparkle (provided key)"
  SIG_ATTRS="$("$SIGN_UPDATE" "$DMG" -s "$SPARKLE_PRIVATE_KEY")"
elif SIG_ATTRS="$("$SIGN_UPDATE" "$DMG" 2>/dev/null)"; then
  echo "==> EdDSA-signed the DMG for Sparkle (keychain key)"
else
  echo "note: no Sparkle EdDSA key (set SPARKLE_PRIVATE_KEY or run generate_keys); skipping appcast." >&2
  SIG_ATTRS=""
fi
if [ -n "$SIG_ATTRS" ]; then
  {
    echo "SHORT_VERSION=$SHORT_VERSION"
    echo "BUILD_NUMBER=$BUILD_NUMBER"
    # Single-quoted: the value holds spaces and double quotes (sparkle:edSignature="…" length="…").
    echo "ENCLOSURE_ATTRS='$SIG_ATTRS'"
  } >"$BUILD/appcast-fields.env"
  echo "    appcast fields → $BUILD/appcast-fields.env ($SIG_ATTRS)"
fi

echo "✅ Notarized + stapled installer: $DMG"
