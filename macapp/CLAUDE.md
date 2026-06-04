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
```

Reuse `DerivedData/` so SwiftTerm isn't re-resolved every build.

## Gotchas

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

`WorkroomApp/Core/` — store, CLI wrapper, terminal sessions, models, theme.
`WorkroomApp/Views/` — `NavigationSplitView` tree sidebar + terminal detail.
`Scripts/` — `run.sh` (local), `build-helper.sh` (embeds+signs the Go binary), `release.sh`,
`make-icon.swift` (regenerates the `AppIcon` PNGs in `Assets.xcassets` — run `swift Scripts/make-icon.swift`).
