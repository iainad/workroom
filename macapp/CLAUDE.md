# macapp/CLAUDE.md

The Workroom macOS app: a SwiftUI (macOS 13+) front-end that bundles the `workroom`
Go binary and drives it over the CLI's `--json` contract. See README.md for full
architecture, signing, and notarization detail — this file is the quick reference.

## Build & run

```bash
Scripts/run.sh          # canonical local loop: xcodegen (if needed) → xcodebuild → relaunch
```

Or by hand:

```bash
xcodegen generate                                                   # regenerate .xcodeproj (gitignored)
xcodebuild -project WorkroomApp.xcodeproj -scheme WorkroomApp \
  -configuration Debug -derivedDataPath DerivedData build

xcodebuild test -project WorkroomApp.xcodeproj -scheme WorkroomApp \
  -configuration Debug -derivedDataPath DerivedData -destination 'platform=macOS'  # WorkroomAppTests
```

Reuse `DerivedData/` so SwiftTerm isn't re-resolved every build.

## Formatting & linting

Swift is formatted and linted with **swift-format** (bundled with the Xcode toolchain — run via
`xcrun swift-format`, no install needed). Config is `macapp/.swift-format` (2-space indent, 100
columns); it covers `WorkroomApp/` + `WorkroomAppTests/` only (not the `Scripts/*.swift` tools).

```bash
make format    # = Scripts/format.sh — rewrite sources in place
make lint      # = Scripts/lint.sh   — --strict, non-zero on any violation (CI gate)
```

Every Xcode/`xcodebuild` build also runs a `swift-format lint` pre-build phase that surfaces
violations as **warnings** (non-fatal, so it won't block local builds — `make lint` is the hard
gate). Run `make format` before committing.

## Gotchas

- **The Swift module is `Workroom`, not `WorkroomApp`** (the target is `WorkroomApp`, but
  `PRODUCT_NAME`/module is `Workroom`). Tests use `@testable import Workroom`, and a test
  target's `TEST_HOST` must point at `Workroom.app/Contents/MacOS/Workroom` — XcodeGen's
  auto-derived (target-name-based) host is wrong and fails with "Could not find test host".
- **New `.swift` file → run `xcodegen generate` first.** XcodeGen expands the source
  glob into explicit file refs in the (gitignored) `.xcodeproj`, so a new file is
  invisible to `xcodebuild`/Xcode until the project is regenerated.
- **SourceKit "Cannot find type X in scope" is usually noise.** The single-file indexer
  doesn't see sibling files; a clean `xcodebuild` is authoritative.
- **SwiftTerm is pinned to `exactVersion: 1.13.0`** (project.yml) — tip-of-`main`
  references an undefined `SyncDebug` and won't compile. Don't float it to a branch.
- **Menu enable/disable must flow through `focusedSceneValue` + `@FocusedValue`**
  (see `WorkroomApp.swift`); a `Commands` body does not re-evaluate when the shared
  `AppStore` mutates. ⌘1–9 are handled by an `NSEvent` local monitor in `AppDelegate`,
  not menu items, so they fire before the terminal swallows the keys.

## Layout

**VCS info that only the GUI needs** (e.g. the sidebar root row's current branch/bookmark)
is resolved app-side in `Core/BranchResolver.swift` (per project, async, with a per-call
timeout) — deliberately NOT added to the `workroom --json` contract, which the human CLI
never shows.

`WorkroomApp/Core/` — store, CLI wrapper, terminal sessions, models, theme.
`WorkroomApp/Views/` — `NavigationSplitView` tree sidebar + terminal detail.
`Scripts/` — `run.sh` (local), `build-helper.sh` (embeds+signs the Go binary), `release.sh`,
`make-icon.swift` (regenerates the `AppIcon` PNGs in `Assets.xcassets` — run `swift Scripts/make-icon.swift`).
