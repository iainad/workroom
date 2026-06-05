# TODOs

## Live branch-label refresh (macapp)

**What:** Update each sidebar root row's branch/bookmark the moment it changes, rather
than on the throttled app-reactivate refresh.

**Why:** Today the root label resolves on load and refreshes (throttled) when the app
regains focus. If you switch branches in the root terminal and stay in the app, the label
is stale until you alt-tab away and back.

**How to start:** Per-project watcher — FSEvents on `<repo>/.git/HEAD` (git) and a `jj op
log` / `.jj/` watch (jj), debounced, re-running `BranchResolver` for that one project and
writing `AppStore.rootRefs[project.id]`. Tie the watchers' lifecycle to the project list.

**Depends on:** the `BranchResolver` + `rootRefs` machinery already in place
(`macapp/WorkroomApp/Core/BranchResolver.swift`, `Core/AppStore.swift`).

**Priority:** P3 (nicety — the throttled focus refresh covers the common case).

## Auto-emit OSC notifications on command completion (macapp)

**What:** An opt-in shell hook (zsh `precmd`/`preexec`, or OSC 133 prompt markers) that emits
`printf '\e]9;<cmd> finished\a'` after a command that ran longer than N seconds, so notifications
fire automatically without the user wrapping commands.

**Why:** Notification detection is explicit-only (issue #10 review, decision 1.1b): we notify on
OSC 9/99/777 + bell, not raw output. That's precise but silent for a bare `make test` that emits
nothing. A shell hook closes that gap so the common "my build finished" case just works.

**How to start:** Source a hook into the login shell launched by
`TerminalSessions.makeTerminal` (`-l`), or document it for the user to add. Decide OSC 133 vs a
`precmd` that emits OSC 9. Keep it opt-in (injecting into the user's shell is invasive).

**Depends on:** the notifications feature (issue #10) landing — the OSC 9 handler must exist to
receive it (`macapp/WorkroomApp/Core/ActivityTerminalView.swift`).

**Priority:** P3 (amplifies the shipped feature; the feature is useful without it for tools that
already emit OSC/bell).

## Notification preferences (macapp)

**What:** Per-workroom (or per-terminal) mute, a notification-sound toggle, and respecting macOS
Focus / Do-Not-Disturb.

**Why:** Once notifications exist, a noisy cooperating tool (a watcher firing OSC on every rebuild)
will need silencing without losing notifications from other terminals. Focus/DND respect is largely
automatic via `UNUserNotificationCenter`; per-workroom mute is app logic.

**How to start:** A mute set keyed on `TerminalTarget.ID`, checked in
`NotificationCenterStore.record(...)` before creating an item / posting. Persist with `@AppStorage`
(consistent with theme / copy-on-select). A sound toggle gates `content.sound` in `SystemNotifier`.

**Depends on:** the notifications feature (issue #10) landing
(`macapp/WorkroomApp/Core/NotificationCenterStore.swift`, `Core/SystemNotifier.swift`).

**Priority:** P3 (the feature is usable without it; add when a real terminal proves too chatty).

## Own the GhosttyKit xcframework before GA (macapp) — CMT-2

**What:** Stop consuming the third-party `libghostty-spm` (Lakr233) package. Fork Ghostty, build
the universal `GhosttyKit.xcframework` (`macos-arm64_x86_64`) + resources tarball in a *separate*
repo's CI, publish them as release artifacts, and switch `project.yml` to that source.

**Why:** libghostty's embedding C API is explicitly unstable/internal ("breaking changes are
expected"). We pin `exactVersion: 1.2.3` today, but the pin is on someone else's repackaging —
if it lags upstream or stalls we have no recourse. Muxy (the blueprint) forked rather than trust a
packager for exactly this reason. Owning the pin is the locked pre-GA checkpoint (CMT-2). No Zig
toolchain is needed to *consume* the xcframework — only to *build* the fork, which lives in the
separate repo's CI, not Workroom's build.

**How to start:** Fork `ghostty-org/ghostty`; add CI that builds the xcframework + bundles
`terminfo`/`shell-integration`; publish both as release assets. In `macapp/project.yml`, point the
`libghostty` package at the fork's release (or vendor the xcframework + a 2-file C shim, as Muxy
does, linking the static archive via `.unsafeFlags`). Re-verify signing — still a static archive
in the main executable, so no new framework to sign.

**Depends on:** nothing in-app — it's a dependency-source swap (`macapp/project.yml`,
`macapp/Resources/ghostty/`). Best done while the API surface we use is stable.

**Re-verify after the upgrade (known gaps to recheck):**
- **OSC 99 desktop notifications** — ghostty has no OSC-99 (Kitty notification) parser in any release
  *or* `main` yet (only OSC 9 / 777 notify); `\e]99;;…` parses as invalid and is dropped, so it never
  reaches the app. There's an **open upstream PR — ghostty-org/ghostty#10467** ("parse the Kitty
  desktop notification protocol (OSC 99)"). When building our xcframework, pick a ghostty ref that
  includes #10467 (or cherry-pick it) and confirm OSC 99 fires — the app pipeline is already proven
  via OSC 9. Alternative: ghostty's in-progress libghostty fallback-handler for unknown OSC could let
  us parse OSC 99 app-side instead of patching the engine. OSC 9/777 cover the common cases meanwhile.
  See `macapp/QA-libghostty.md` §H.
- **Backspace keycode encoding** — 1.2.3 mis-encodes the backspace *keycode* (emits a space); we
  work around it by sending DEL as text (`GhosttySurfaceView.filterSpecialCharacters`). If the
  upgrade fixes the keycode path, the workaround can be simplified.

**Priority:** P1 before GA (the migration ships on the third-party pin for the beta).

## Splits feature (macapp) — A5

**What:** The actual split UI: keybindings to split a pane horizontally/vertically, focus
navigation between panes, drag-to-resize the divider, and close-pane.

**Why:** The migration built the model split-ready (A5) — `TerminalTab` already holds a `PaneNode`
tree (leaf = one `GhosttySurfaceView`; node = split + orientation), and the host renders it (today
always a single leaf, so behaviour == pre-splits). Only the interaction layer is missing.

**How to start:** Extend `PaneNode` construction in `TerminalSessions` (split the focused leaf into
a node); render the node recursively with a divider in `Views/TerminalContainerView.swift`; per-leaf
occlusion is already wired (A4). Add commands/keybindings in `WorkroomApp.swift`. Crib Muxy's
`SplitNode` interaction as inspiration only (D1 — no Muxy extras).

**Depends on:** the pane-tree model already in place
(`macapp/WorkroomApp/Models/TerminalPane.swift`, `Core/TerminalSessions.swift`,
`Views/TerminalContainerView.swift`).

**Priority:** P2 (the user wants splits "in the very near future"; the groundwork is done).

## Terminal accessibility (macapp) — CMT-3

**What:** VoiceOver support on `GhosttySurfaceView` — `accessibilitySelectedText`, accessible
value/role, and focus reporting, so the terminal is navigable with assistive tech.

**Why:** SwiftTerm provided some a11y for free; the hand-rolled libghostty surface currently
provides none (accepted regression for the beta, CMT-3). `ghostty_surface_read_selection` already
gives us the selected text to expose.

**How to start:** Override the `NSAccessibility` protocol methods on `GhosttySurfaceView`; back
`accessibilitySelectedText()` with `ghostty_surface_read_selection` (same read that powers
copy-on-select); set an appropriate role. Reference Muxy's `accessibilitySelectedText()`.

**Depends on:** the selection read already implemented
(`macapp/WorkroomApp/Core/GhosttySurfaceView.swift`).

**Priority:** P2 (accessibility regression — address before GA, not blocking the beta).

## Memory / live-surface diagnostics (macapp)

**What:** Lightweight instrumentation of live `ghostty_surface_t` count and process memory, to
catch leaks/growth at high tab counts.

**Why:** Each surface is a GPU-backed Metal layer; the plan flags the 50–100-tab surface budget as
"measure, don't assume." Occlusion is wired (A4) so off-screen surfaces idle, but magnitude at
Workroom's tab counts is unverified. Muxy ships a 458-line `MemoryDiagnostics` for this reason.

**How to start:** A periodic sampler logging `tabsByTarget` leaf count + `mach_task_basic_info`
resident size via `os.Logger`; optionally a debug overlay. Keep it far lighter than Muxy's — a
counter + a memory read, not crash-crumb recovery (D1).

**Depends on:** `TerminalSessions` (surface inventory), `GhosttyApp` (`os.Logger` already set up).

**Priority:** P3 (diagnostic aid; pair with the manual surface-budget QA pass).

## OSC 52 clipboard-confirmation policy (macapp)

**What:** A real policy/UI for terminal-app clipboard access (OSC 52) — the runtime's
`read_clipboard_cb` / `write_clipboard_cb`. Today writes are gated to `text/*` mime and reads use
Ghostty's permissive default (auto-allow); a deliberate prompt/allowlist is deferred.

**Why:** Code-review finding #7. OSC 52 lets a remote program read/write the system pasteboard;
the permissive default is fine for a beta (it matches Ghostty's own default) but a security-minded
user should be able to require confirmation.

**How to start:** Implement `confirm_read_clipboard_cb` to surface a prompt (or consult an
`@AppStorage` policy: allow / prompt / deny); gate `write_clipboard_cb` similarly. Decide the
default (Ghostty = allow).

**Depends on:** the clipboard callbacks already wired
(`macapp/WorkroomApp/Core/GhosttyRuntimeAdapter.swift`, `Core/GhosttyApp.swift`).

**Priority:** P3 (permissive default is acceptable for the beta).
