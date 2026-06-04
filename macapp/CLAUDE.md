# macapp/CLAUDE.md

The Workroom macOS app: a SwiftUI (macOS 14+) front-end that bundles the `workroom`
Go binary and drives it over the CLI's `--json` contract. See README.md for full
architecture, signing, and notarization detail — this file is the quick reference.

## Dev tasks (Makefile)

Every dev task runs through the **repo-root `Makefile`**, namespaced `app-*` (run from the repo
root, not `macapp/`):

```bash
make app-run        # canonical local loop: xcodegen (if needed) → xcodebuild (Debug) → relaunch
make app-build      # xcodegen (if needed) → xcodebuild (Debug)
make app-test       # xcodebuild test (WorkroomAppTests)
make app-generate   # force-regenerate the (gitignored) .xcodeproj from project.yml
make app-format     # swift-format, rewrite sources in place
make app-lint       # swift-format --strict (non-zero on any violation — the hard gate)
make app-release    # Release build → notarize → staple → DMG installer (Scripts/release.sh)
make app-icon       # regenerate AppIcon PNGs (Scripts/make-icon.swift)
make app-clean      # remove DerivedData + .xcodeproj
```

Builds reuse `macapp/DerivedData/` so SwiftTerm isn't re-resolved every build. (`cli-*` targets
cover the Go CLI — see the root CLAUDE.md.)

## Formatting & linting

Swift is formatted/linted with **swift-format** (bundled with the Xcode toolchain — run via
`xcrun swift-format`, no install). Config `macapp/.swift-format` (2-space, 100 cols) covers
`WorkroomApp/` + `WorkroomAppTests/` only (not the `Scripts/*.swift` tools). Use `make app-format`
/ `make app-lint`. Every Xcode/`xcodebuild` build also runs a `swift-format lint` pre-build phase
that surfaces violations as **warnings** (non-fatal — `make app-lint` is the hard gate). Run
`make app-format` before committing.

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
