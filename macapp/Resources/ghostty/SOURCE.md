# Bundled libghostty runtime resources

`GHOSTTY_RESOURCES_DIR` points here at launch (see Core/GhosttyApp.swift). libghostty needs:

- `terminfo/` — the `xterm-ghostty` / `ghostty` terminfo entries. libghostty sets
  `TERM=xterm-ghostty` for the shell but NOT `TERMINFO`, and macOS has no system entry for it, so
  `GhosttyApp` also exports `TERMINFO` → here (without it the shell can't resolve the terminal's
  capabilities and line editing — e.g. Backspace — breaks).
- `shell-integration/` — per-shell scripts Ghostty auto-injects; these report OSC 7 pwd
  (the cwd source for ⌘-click path resolution — see plan CMT-1) and more.

The `libghostty-spm` package ships NO resources, so these are vendored. Sourced from a recent
Ghostty build. **TODO (pre-GA, CMT-2):** when we move to a self-built xcframework from a pinned
Ghostty fork, regenerate these from that exact tag so they version-match the binary.
Themes are intentionally omitted (Workroom themes via macOS system colors, not Ghostty themes).
