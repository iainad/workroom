#!/usr/bin/env bash
# Format the app + test Swift sources in place with swift-format (config: macapp/.swift-format).
# swift-format ships with the Xcode toolchain, so `xcrun` finds it — no separate install needed.
set -euo pipefail
cd "$(dirname "$0")/.."
exec xcrun swift-format format --in-place --parallel --recursive WorkroomApp WorkroomAppTests
