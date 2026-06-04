# Workroom — macOS app

A native SwiftUI app that manages projects and their workrooms and opens a built-in
terminal (SwiftTerm) in each. It integrates the `workroom` Go CLI by **bundling the
binary** and shelling out over its `--json` contract — no cgo, no duplicated logic.

> Status: **builds clean.** `xcodegen generate` + `xcodebuild` compiles the app and
> SwiftTerm with zero warnings in our sources, embeds + (ad-hoc) signs the Go helper,
> and the helper speaks the `--json` contract. Runtime behaviour (terminals, mutations,
> shell reaping) still wants hands-on QA in Xcode. The CLI contract is unit-tested in
> the parent Go module.

## Prerequisites

- Xcode 15+ (macOS 13+ deployment target)
- Go (to build the embedded helper) — must be on `PATH`, or edit `Scripts/build-helper.sh`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build & run

```bash
cd macapp
xcodegen generate          # writes WorkroomApp.xcodeproj (gitignored) from project.yml
open WorkroomApp.xcodeproj  # then ⌘R in Xcode
```

Or use the repo-root Makefile — the single entry point for every dev task, with the app
namespaced under `app-*` (run from the **repo root**):

```bash
make app-run        # xcodegen (if needed) → xcodebuild (Debug) → relaunch the app
make app-build      # build only
make app-test       # run WorkroomAppTests
make app-format     # swift-format, rewrite sources in place
make app-lint       # swift-format --strict
make app-generate   # force-regenerate the .xcodeproj
make app-release    # notarized Release build (see below)
```

> **Adding a source file?** Run `make app-generate` first. XcodeGen expands the `WorkroomApp/`
> source glob into explicit file references in the (gitignored) `.xcodeproj`, so a newly added
> `.swift` file stays invisible to Xcode and `xcodebuild` until the project is regenerated.
> (`make app-run`/`make app-build` only regenerate when the `.xcodeproj` is missing, so
> regenerate by hand after adding files.)

Xcode resolves the SwiftTerm Swift Package, and the `Build & embed workroom helper`
script phase (`Scripts/build-helper.sh`) compiles the Go CLI into
`Workroom.app/Contents/Resources/workroom` and signs it. (Resources, not
`Contents/MacOS`: a helper named `workroom` there would collide with the `Workroom`
app executable on the case-insensitive filesystem.)

## Signing & distribution

The project is configured for team **B898J443L9**:
- **Debug** (`⌘R`): automatic signing with your *Apple Development* cert.
- **Release**: manual signing with *Developer ID Application*, hardened runtime, secure
  timestamp. `Scripts/build-helper.sh` signs the embedded helper the same way before the
  app's final signature.

To produce a notarized, stapled `Workroom.app`, first store notary credentials once
(app-specific password from appleid.apple.com — not your Apple ID password):

```bash
xcrun notarytool store-credentials "workroom-notary" \
    --apple-id "you@example.com" --team-id B898J443L9 --password "abcd-efgh-ijkl-mnop"
```

Then:

```bash
make app-release   # builds Release, verifies signing, notarizes, staples, spctl-checks (Scripts/release.sh)
```

Prefer not to use XcodeGen? Create a SwiftUI macOS App target manually, add the
SwiftTerm package, add the `WorkroomApp/` sources, and add `Scripts/build-helper.sh`
as a Run Script phase **after Compile Sources**.

## Architecture

- `WorkroomApp.swift` — `@main`; sets `PATH` at launch so the helper/terminals find git/jj.
- `Core/WorkroomCLI.swift` — `Process` wrapper over the bundled binary: locates it in the
  bundle, overlays `PATH` onto the inherited env, drains stdout/stderr concurrently,
  enforces per-command timeouts, and decodes the JSON envelope (`ok` / `error.kind`).
- `Core/AppStore.swift` — `@MainActor` store; loads via `list --json` (config-only first,
  then `--warnings=fast`), and mutates via `add-project` / `create` / `delete`.
- `Core/TerminalSessions.swift` — caches one live terminal **per workroom** for the app
  session so switching doesn't kill running shells (decision D2).
- `Views/` — `NavigationSplitView`: projects sidebar · workroom list · terminal detail,
  with empty/error states, a destructive delete confirmation, and a detail toolbar.
- `Core/Models.swift` — `Codable` mirrors of the `--json` contract (lenient decoding).

## Things to verify on first build (marked `TODO` in code)

1. **SwiftTerm pin** (`project.yml`): pinned to `exactVersion: 1.13.0` — it exposes
   `startProcess(… currentDirectory:)` and compiles cleanly. (Tip-of-`main` currently
   references an undefined `SyncDebug` and fails to build, so do not float the pin to a
   branch.) ✓ verified: the app builds against it.
2. **Terminal termination** (`TerminalSessions.terminate`): ✓ implemented via
   `LocalProcessTerminalView.process.terminate()` (SIGTERM). Still worth a runtime check:
   switch/delete workrooms repeatedly and confirm no orphaned shells in `ps`.
3. **Signing/notarization**: ✓ configured (Developer ID for Release, team B898J443L9;
   helper signed by `Scripts/build-helper.sh`). Run `Scripts/release.sh` to build + notarize
   + staple (after the one-time `notarytool store-credentials` above). See "Signing &
   distribution".
4. **Process-group kill** (`WorkroomCLI.run`): the MVP uses `terminate()` + non-interactive
   git env; a full group-kill of git/jj grandchildren would need a `posix_spawn` launch.
