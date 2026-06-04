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
