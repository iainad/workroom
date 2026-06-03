#!/bin/bash
#
# Build and launch the Workroom app locally (Debug) from the command line — no Xcode UI.
# Local runs sign with your Apple Development cert; Developer ID + notarization are only
# for distributing to other machines (see release.sh).
set -euo pipefail

MACAPP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$MACAPP_DIR"
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"   # xcodegen, go, etc.

[ -d WorkroomApp.xcodeproj ] || xcodegen generate

# Reuses ./DerivedData so SwiftTerm isn't re-resolved/recompiled — fast incremental builds.
xcodebuild -project WorkroomApp.xcodeproj -scheme WorkroomApp -configuration Debug \
  -derivedDataPath DerivedData \
  -clonedSourcePackagesDirPath DerivedData/SourcePackages \
  build

APP="DerivedData/Build/Products/Debug/Workroom.app"

# Quit any running instance first. `open` only *activates* an already-running app
# (matched by bundle id, even one launched from another location), so without this it
# would silently keep running the previous build — your new changes never appear.
# pkill (not AppleScript `tell ... to quit`, which prompts for Automation access and
# even launches the app just to quit it when it isn't already running).
if pgrep -x Workroom >/dev/null 2>&1; then
  pkill -x Workroom 2>/dev/null || true
  # Wait for it to actually exit so `open` launches the fresh binary.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Workroom >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

echo "Launching $APP"
open "$APP"
