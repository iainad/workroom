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

## Own the GhosttyKit xcframework (macapp) — CMT-2

**What:** Stop depending on the third-party `libghostty-spm` (Lakr233) package as the source of
truth. Build our own universal `GhosttyKit.xcframework` (`macos-arm64_x86_64`) + version-matched
resources from a ghostty ref *we* pin, and point `project.yml` at it.

**When (trigger-based, lean sooner than "vague pre-GA"):** Not needed for the beta — `1.2.3` works
with our fixes (see the keyboard-input + terminal-input commits). Do it when the **first concrete
trigger** hits, and treat it as the **next infra task after the beta stabilizes**:
- We want an **unreleased ghostty change** — concretely **OSC 99** (PR #10467), the backspace-keycode
  fix, or the libghostty OSC fallback-handler — none of which exist in any ghostty *release*, so no
  libghostty-spm release can ever deliver them.
- We want to be on **ghostty 1.3.x** (see lag below).
- libghostty-spm stalls or makes a pin choice we don't want.
- **GA** — do it regardless of features: shipping GA on a single-maintainer repackaging of an
  explicitly-unstable API is a supply-chain risk; owning the pin is the control.

**Why (reinforced by observed facts, 2026-06-05):**
- The embedding C API is explicitly unstable/internal ("breaking changes are expected").
- **The packager already lags upstream.** ghostty has released **v1.3.0 and v1.3.1**, but
  libghostty-spm is still on **`1.2.3`** (published 2026-06-01; tags 1.2.1→1.2.3 only). So "just use
  new libghostty-spm releases as they arrive" means trailing ghostty by ~2 versions on a single
  maintainer's cadence — the exact "packager lags" risk, now real, not hypothetical.
- Everything we'll want next (OSC 99 etc.) lives **upstream of any release** — only the owner-of-the-pin
  path can reach it. Muxy forked for exactly this reason.

**How to start (cheaper than a full fork — reuse the packager's tooling):**
- libghostty-spm ships a **`build.sh`** that builds the xcframework from a ghostty source dir
  (`./build.sh --source /path/to/ghostty …`). So: clone `ghostty-org/ghostty` at the chosen ref (a
  release tag, or a branch with PR #10467 cherry-picked), run `build.sh`, and **regenerate
  `terminfo`/`shell-integration` from that same ref** (fixes the SOURCE.md version-skew TODO).
- Vendor the resulting xcframework + a 2-file C shim (`GhosttyKit.c` + `module.modulemap` exposing
  `ghostty.h`), linking the static archive via `.unsafeFlags`, **or** host it as a release artifact in
  a separate repo's CI and point the SPM package there. Zig is needed only to *build*, not to
  *consume*.
- Re-verify signing — still a static archive in the main executable, so no new framework to sign
  (plan §4).

**Depends on:** nothing in-app — it's a dependency-source swap (`macapp/project.yml`,
`macapp/Resources/ghostty/`). Best done when we've picked the target ghostty ref.

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

**Priority:** P2 now / **P1 before GA**. Trigger-based: not blocking the beta (ships on the
third-party pin), but it's the next infra task once the beta is stable — and the observed packager
lag (1.2.3 vs ghostty 1.3.1) means leaning sooner beats waiting on the packager.

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

**What:** VoiceOver support on `GhosttySurfaceView` — accessible value (screen text), selected
text, and focus reporting, so the terminal is navigable with assistive tech.

**Why:** SwiftTerm (an NSView text control) provided some a11y for free; the libghostty surface is
Metal-rendered, so its content is pixels — invisible to the accessibility system. Today the view
only sets `role=.textArea` + a label ("Terminal — <dir>"); it exposes **no value and no selection**,
so VoiceOver reads nothing. Accepted regression for the beta (CMT-3). Doubles as the **enabler for
content-level UI tests**: once terminal text is in the a11y tree, XCUITest can assert on rendered
output (backspace deleted, TUI drew, scrollback) — see `macapp/QA-libghostty.md` (Bucket 2).

**When:** **sequence with the xcframework upgrade** (CMT-2), not now. Feasible on 1.2.3 today (read
APIs exist), but ghostty upstream has merged a11y plumbing we'd want to ride — e.g.
**ghostty #12902** ("core: send selection_changed notification"), which on macOS posts
`.ghosttySelectionDidChange` → debounced → `NSAccessibility.selectedTextChanged`. On 1.2.3 we'd have
to post that notification ourselves on our own selection events; post-upgrade it comes from the
engine. A before-GA item.

**How to start (minimal-viable, keep light per D1 — crib Muxy's `accessibilitySelectedText()`):**
- `accessibilityValue()` → visible screen text via `ghostty_surface_read_text(surface, <viewport
  ghostty_selection_s>, …)` (reuse the `extractString(from:)` helper).
- `accessibilitySelectedText()` → `ghostty_surface_read_selection` (the same read that powers
  copy-on-select).
- Post `NSAccessibility.post(element:notification:)` `.selectedTextChanged` on selection change
  (we already detect mouseUp / copy-on-select) and a throttled `.valueChanged` on output so
  VoiceOver follows along; keep the role/label and report focus.
- Skip the full `NSAccessibility` text protocol (line/char-range/bounds geometry) — overkill for a
  terminal, and Muxy keeps it minimal too.

**Caveat:** terminal a11y is inherently partial (dynamic output, scrollback, full-screen TUIs);
target "announce output + selection, navigable text", not a perfect document model.

**Depends on:** the read APIs already present in 1.2.3 (`ghostty_surface_read_selection`,
`ghostty_surface_read_text`, `extractString`) in `macapp/WorkroomApp/Core/GhosttySurfaceView.swift`;
best done after CMT-2 to use ghostty's `selection_changed` hook.

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

## UI-testing fixture seam (macapp)

**What:** A launch-argument-driven fixture mode so XCUITest gets deterministic app state — e.g.
`-uitesting` (or `WORKROOM_UITEST_FIXTURE=…`) makes `AppStore.bootstrap` load fake projects /
workrooms instead of the developer's real `~/.config/workroom`.

**Why:** The starter UI suite (`macapp/WorkroomAppUITests`, run via `make app-uitest`) currently has
a deterministic smoke test plus **opportunistic** workflow tests that `XCTSkip` when no project /
workroom is configured — because the app loads real config, so tab/notification/delete flows can't
assert deterministically (and aren't CI-able). A fixture seam makes those flows reliable and lets us
add the deferred tests (notification badge + click-to-navigate, delete-clears-badges).

**How to start:** Read a launch arg in `WorkroomApp`/`AppStore` (only when present) and inject a
fixture list through the existing CLI-`--json` boundary (or a test-only store seam) so no real `git`/
`jj` runs. Then flesh out the skipped tests in `WorkroomWorkflowUITests` and drop the skips. Pairs
with **CMT-3** (terminal accessibility) which unlocks terminal-*content* assertions on top of this.

**Depends on:** the UI test target + accessibility identifiers already in place
(`macapp/project.yml`, `WorkroomAppUITests/`, identifiers in `Views/ProjectSidebar.swift` +
`Views/WorkroomTerminalsView.swift`).

**Priority:** P3 (the smoke test + opportunistic suite are useful now; deterministic/CI runs want
this).
