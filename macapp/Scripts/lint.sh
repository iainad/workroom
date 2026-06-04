#!/usr/bin/env bash
# Lint the app + test Swift sources with swift-format (config: macapp/.swift-format).
# `--strict` exits non-zero on any violation, so this gates `make lint` and CI. (The Xcode
# build phase runs lint non-strict, surfacing warnings without failing local builds.)
set -euo pipefail
cd "$(dirname "$0")/.."
exec xcrun swift-format lint --strict --parallel --recursive WorkroomApp WorkroomAppTests
