#!/bin/bash
#
# Merge this release into the Sparkle appcast and publish it as an asset on the fixed `appcast`
# GitHub release — the stable SUFeedURL the app is built with. Run in CI after the DMG is
# uploaded; reads the fields Scripts/release.sh wrote to build/release/appcast-fields.env (which
# only exist when the DMG was EdDSA-signed, i.e. SPARKLE_PRIVATE_KEY is configured).
#
# Required env: TAG (e.g. v1.4.0), REPO (owner/repo), GH_TOKEN (for `gh`).
set -euo pipefail

MACAPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${MACAPP_DIR}/build/release"
FIELDS="${BUILD}/appcast-fields.env"
FEED="${BUILD}/appcast.xml"
FEED_TAG="appcast"  # the fixed release that hosts appcast.xml (matches SUFeedURL)
MIN_OS="14.0"

# No signed fields → Sparkle isn't set up yet (no SPARKLE_PRIVATE_KEY). Skip without failing the
# release, so the DMG still ships and auto-update activates once the key is configured.
if [ ! -f "$FIELDS" ]; then
  echo "note: $FIELDS not found — DMG wasn't EdDSA-signed (set the SPARKLE_PRIVATE_KEY secret to" \
    "enable the appcast). Skipping appcast publish." >&2
  exit 0
fi

# shellcheck disable=SC1090
. "$FIELDS"  # SHORT_VERSION, BUILD_NUMBER, ENCLOSURE_ATTRS
: "${TAG:?TAG required}"
: "${REPO:?REPO required}"

# Must match the asset name the release workflow uploads (workroom-macos-app_<version>.dmg,
# version without the tag's leading v).
DMG_URL="https://github.com/${REPO}/releases/download/${TAG}/workroom-macos-app_${TAG#v}.dmg"
NOTES_URL="https://github.com/${REPO}/releases/tag/${TAG}"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# Fetch the current feed, or start a skeleton if the appcast release/asset doesn't exist yet.
if gh release download "$FEED_TAG" --repo "$REPO" --dir "$BUILD" -p appcast.xml --clobber 2>/dev/null; then
  echo "Fetched existing appcast.xml"
else
  echo "Initializing new appcast.xml"
  cat >"$FEED" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Workroom</title>
  </channel>
</rss>
XML
fi

ITEM=$(
  cat <<XML
    <item>
      <title>Workroom ${SHORT_VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${MIN_OS}</sparkle:minimumSystemVersion>
      <link>${NOTES_URL}</link>
      <enclosure url="${DMG_URL}" ${ENCLOSURE_ATTRS} type="application/octet-stream" />
    </item>
XML
)

# Insert as the newest item (idempotent on sparkle:version, so re-running a tag is safe).
ITEM="$ITEM" BUILD_NUMBER="$BUILD_NUMBER" python3 - "$FEED" <<'PY'
import os, re, sys
path = sys.argv[1]
item = os.environ["ITEM"]
build = os.environ["BUILD_NUMBER"]
xml = open(path, encoding="utf-8").read()
if f"<sparkle:version>{build}</sparkle:version>" in xml:
    print(f"appcast already lists build {build}; leaving unchanged")
    sys.exit(0)
m = re.search(r"[ \t]*<item>", xml)          # newest-first: before the first existing item…
if m:
    xml = xml[: m.start()] + item + "\n" + xml[m.start():]
else:                                        # …or before </channel> when there are none yet
    xml = xml.replace("</channel>", item + "\n  </channel>", 1)
open(path, "w", encoding="utf-8").write(xml)
print(f"Inserted appcast item for build {build} ({sys.argv[1]})")
PY

# Publish: ensure the feed release exists (not "Latest"), then re-upload the asset.
gh release view "$FEED_TAG" --repo "$REPO" >/dev/null 2>&1 ||
  gh release create "$FEED_TAG" --repo "$REPO" --title "Appcast" --prerelease \
    --notes "Sparkle update feed for the Workroom macOS app — not a download. Do not delete."
gh release upload "$FEED_TAG" "$FEED" --repo "$REPO" --clobber
echo "✅ Published appcast.xml to the '${FEED_TAG}' release"
