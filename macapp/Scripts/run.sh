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
echo "Launching $APP"
open "$APP"
