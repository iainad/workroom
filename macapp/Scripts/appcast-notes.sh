#!/bin/bash
#
# Refresh a published appcast item's <description> from the *current* GitHub release notes.
#
# The build-time appcast (Scripts/appcast.sh) embeds whatever the release body holds when the DMG
# ships — which is usually goreleaser's raw commit list, because the human-curated notes are written
# later. This script re-renders the matching item's <description> from the release's current body so
# the in-app Sparkle update dialog shows the curated notes, not the commit list. It runs on every
# `release: edited` event (see .github/workflows/appcast-notes.yml) and is safe to re-run by hand.
#
# It needs no build output — it locates the item by its <link> (…/releases/tag/$TAG), so it works
# long after the build that produced the DMG is gone.
#
# Required env: TAG (e.g. v1.4.0), REPO (owner/repo), GH_TOKEN (for `gh`).
set -euo pipefail

MACAPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${MACAPP_DIR}/build/release"
FEED="${BUILD}/appcast.xml"
FEED_TAG="appcast"  # the fixed release that hosts appcast.xml (matches SUFeedURL)
mkdir -p "$BUILD"

: "${TAG:?TAG required}"
: "${REPO:?REPO required}"

# The feed only ever versions the app; ignore edits to the feed release itself or any non-version tag.
case "$TAG" in
  appcast | "") echo "note: TAG '$TAG' is not a version release; nothing to refresh." >&2; exit 0 ;;
esac

NOTES_URL="https://github.com/${REPO}/releases/tag/${TAG}"

# Render the release body to HTML (the same GFM the release page shows). No body → nothing to embed.
NOTES_MD="$(gh release view "$TAG" --repo "$REPO" --json body -q .body 2>/dev/null || true)"
if [ -z "$NOTES_MD" ]; then
  echo "note: release $TAG has no body; nothing to embed." >&2
  exit 0
fi
NOTES_HTML="$(gh api --method POST /markdown -f mode=gfm -f context="$REPO" -f text="$NOTES_MD")"
# A CDATA section can't contain the literal "]]>"; split any occurrence so it stays well-formed.
NOTES_HTML="${NOTES_HTML//]]>/]]]]><![CDATA[>}"

# Fetch the published feed. If it doesn't exist yet there's nothing to refresh (the build publishes it).
if ! gh release download "$FEED_TAG" --repo "$REPO" --dir "$BUILD" -p appcast.xml --clobber 2>/dev/null; then
  echo "note: no published appcast.xml yet; nothing to refresh." >&2
  exit 0
fi

# Exit 0 = feed rewritten (upload it); 9 = item missing or already current (skip the upload).
set +e
NOTES_HTML="$NOTES_HTML" NOTES_URL="$NOTES_URL" python3 - "$FEED" <<'PY'
import os, re, sys

path = sys.argv[1]
html = os.environ["NOTES_HTML"]
link = os.environ["NOTES_URL"]
xml = open(path, encoding="utf-8").read()

# Locate the <item> for this release by its <link> (the tag page URL).
target = next(
    (m for m in re.finditer(r"<item>.*?</item>", xml, re.S) if f"<link>{link}</link>" in m.group(0)),
    None,
)
if target is None:
    print(f"appcast has no item for {link}; nothing to refresh.")
    sys.exit(9)

block = target.group(0)
desc = f"<description><![CDATA[{html}]]></description>"
if "<description>" in block:
    # Replace via a function so backslashes/group-refs in the HTML aren't interpreted.
    new_block = re.sub(r"<description>.*?</description>", lambda _m: desc, block, count=1, flags=re.S)
else:
    new_block = block.replace(f"<link>{link}</link>", f"<link>{link}</link>\n      {desc}", 1)

if new_block == block:
    print("appcast description already current; leaving unchanged.")
    sys.exit(9)

xml = xml[: target.start()] + new_block + xml[target.end() :]
open(path, "w", encoding="utf-8").write(xml)
print(f"Refreshed appcast description for {link}")
PY
rc=$?
set -e
[ "$rc" -eq 9 ] && exit 0
[ "$rc" -ne 0 ] && exit "$rc"

gh release upload "$FEED_TAG" "$FEED" --repo "$REPO" --clobber
echo "✅ Refreshed appcast.xml notes for ${TAG}"
