import AppKit

/// One terminal tab: a split-ready pane tree (today a single leaf) plus a stable id and title for
/// the tab strip. `view` is the focused/primary leaf's surface — a convenience for the
/// (currently single-pane) host; with splits it becomes the focused pane.
struct TerminalTab: Identifiable {
  let id = UUID()
  let root: PaneNode
  /// Shown until the surface reports a title — and again whenever it reports an empty one.
  let defaultTitle: String
  /// The surface's latest non-empty title (OSC 0/2 via shell integration): the running command
  /// while busy, the working directory when idle. Nil until the first report (issue #2).
  var liveTitle: String?

  /// What the tab strip displays.
  var title: String { liveTitle ?? defaultTitle }

  var view: GhosttySurfaceView { root.firstLeaf.view }
}

/// Owns the live terminals for each target (a workroom or a project root) — one or more tabs each —
/// for the lifetime of the app session, so switching targets or tabs hides/shows terminals instead
/// of tearing them down (a running dev server in one tab survives while you look at another). Keyed
/// on `TerminalTarget.ID`, which is project-scoped, so two same-named workrooms in different projects
/// never share a terminal. Cross-relaunch disk persistence is intentionally out of scope.
@MainActor
final class TerminalSessions: ObservableObject {
  @Published private var tabsByTarget: [TerminalTarget.ID: [TerminalTab]] = [:]
  @Published private var activeByTarget: [TerminalTarget.ID: TerminalTab.ID] = [:]
  /// Per-target running counter so tab titles ("Terminal 1", "2", …) stay stable across closes
  /// rather than renumbering.
  private var counts: [TerminalTarget.ID: Int] = [:]
  /// Set once by `AppStore`: forwards each terminal's notification-worthy activity (OSC) up to the
  /// notification spine. A closure (not a store reference) so sessions stay ignorant of `AppStore`.
  var activityHandler: ((TerminalTarget.ID, TerminalTab.ID, TerminalActivity) -> Void)?

  /// Factory seam (plan T1): how a surface view is created for a target. Overridable in tests so the
  /// lifecycle (add/close/select/move/reap) can be exercised without a real window/shell. Note a
  /// `GhosttySurfaceView` does not spawn its PTY until it enters a window, so the default is already
  /// test-safe; the seam exists so tests can stub it entirely.
  var makeView: (TerminalTarget) -> GhosttySurfaceView = {
    GhosttySurfaceView(workingDirectory: $0.path)
  }

  /// Observes system light/dark changes so terminals re-theme even under the 'System' appearance,
  /// where the user's theme binding (and thus `RootView`'s `onChange`) never fires.
  private var appearanceObserver: NSObjectProtocol?

  init() {
    appearanceObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
      queue: .main
    ) { [weak self] _ in
      // effectiveAppearance settles just after the notification; hop a runloop then re-theme.
      // applyThemeToAll reads NSApp.effectiveAppearance, so a forced (non-System) appearance resolves
      // unchanged and GhosttyApp.reloadConfig coalesces it to a no-op.
      DispatchQueue.main.async { self?.applyThemeToAll() }
    }
  }

  deinit {
    if let appearanceObserver {
      DistributedNotificationCenter.default().removeObserver(appearanceObserver)
    }
  }

  func tabs(for target: TerminalTarget) -> [TerminalTab] {
    tabsByTarget[target.id] ?? []
  }

  func activeTab(for target: TerminalTarget) -> TerminalTab? {
    let tabs = tabsByTarget[target.id] ?? []
    if let id = activeByTarget[target.id], let match = tabs.first(where: { $0.id == id }) {
      return match
    }
    return tabs.first
  }

  /// Create the target's first terminal the first time its pane appears. Once it has been opened, an
  /// emptied tab set is left as-is (the user closed them on purpose).
  func ensureTab(for target: TerminalTarget) {
    if tabsByTarget[target.id] == nil {
      addTab(for: target)
    }
  }

  func addTab(for target: TerminalTarget) {
    let count = (counts[target.id] ?? 0) + 1
    counts[target.id] = count
    let tab = makeTab(for: target, count: count)
    tabsByTarget[target.id, default: []].append(tab)
    activeByTarget[target.id] = tab.id
  }

  func select(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    activeByTarget[target.id] = tabID
  }

  /// Reorder (drag-and-drop in the tab bar): move the dragged tab to `index` in the tab order.
  /// `index` is interpreted against the array *after* the dragged tab is removed, and is clamped to
  /// bounds. The active tab is unaffected.
  func moveTab(_ draggedID: TerminalTab.ID, toIndex index: Int, for target: TerminalTarget) {
    guard var tabs = tabsByTarget[target.id],
      let from = tabs.firstIndex(where: { $0.id == draggedID })
    else { return }
    let moved = tabs.remove(at: from)
    tabs.insert(moved, at: max(0, min(index, tabs.count)))
    tabsByTarget[target.id] = tabs
  }

  /// Close a tab. Closing the last one leaves the target with no terminals — the tab bar (and its
  /// add button) stays, and the active tab becomes nil.
  func closeTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard var tabs = tabsByTarget[target.id],
      let idx = tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    let removed = tabs.remove(at: idx)
    teardown(removed)
    tabsByTarget[target.id] = tabs
    if activeByTarget[target.id] == tabID {
      // Activate the neighbour that slid into this slot, else the new last tab (nil when none remain).
      activeByTarget[target.id] = (idx < tabs.count ? tabs[idx] : tabs.last)?.id
    }
  }

  /// Terminate and forget every terminal for a target (on delete / when its directory disappears) so
  /// we don't leak login shells.
  func reap(_ id: TerminalTarget.ID) {
    for tab in tabsByTarget[id] ?? [] { teardown(tab) }
    tabsByTarget[id] = nil
    activeByTarget[id] = nil
    counts[id] = nil
  }

  func reapAll() {
    for id in Array(tabsByTarget.keys) { reap(id) }
  }

  /// Re-theme every live terminal — visible and hidden alike — to the current app appearance. Driven
  /// from `RootView.applyAppearance()` on each explicit theme change. (System-colors theming detail
  /// is refined in a later step; this propagates the light/dark color scheme to every surface.)
  func applyThemeToAll() {
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    GhosttyApp.shared.reloadConfig()  // rebuild system-colors config for the new appearance (IT7)
    GhosttyApp.shared.setColorScheme(dark: isDark)
    let config = GhosttyApp.shared.config
    for tabs in tabsByTarget.values {
      for tab in tabs {
        for pane in tab.root.leaves {
          if let config { pane.view.updateConfig(config) }
          pane.view.applyColorScheme(isDark: isDark)
        }
      }
    }
  }

  // MARK: Creation

  private func makeTab(for target: TerminalTarget, count: Int) -> TerminalTab {
    let view = makeView(target)
    let tab = TerminalTab(root: .leaf(TerminalPane(view: view)), defaultTitle: "Terminal \(count)")

    // Forward this terminal's activity, tagged with its target + tab id, to the handler.
    // [weak self] + value-type-only captures: the view must not retain sessions.
    let targetID = target.id
    let tabID = tab.id
    view.onActivity = { [weak self] activity in
      self?.activityHandler?(targetID, tabID, activity)
    }

    // Show the running command on the tab, ignoring the directory titles the shell sets at each
    // prompt; clear back to the default when the command finishes (issue #2).
    view.onTitleChange = { [weak self] title in
      self?.updateTitle(title, forTab: tabID, target: targetID)
    }
    view.onCommandFinished = { [weak self] in
      self?.clearLiveTitle(forTab: tabID, target: targetID)
    }

    // ⌘-click link handling (replaces the old AppDelegate NSEvent monitors). cwd comes from the
    // surface's `GHOSTTY_ACTION_PWD`-tracked value (CMT-1); [weak view] avoids a view→closure→view
    // retain cycle.
    let projectPath = target.path
    view.onCmdClickFile = { [weak view] word in
      TerminalLinkOpener.handleCmdClickFile(word, cwd: view?.lastKnownCwd ?? projectPath)
    }
    view.resolveCmdHoverFile = { [weak view] word in
      TerminalLinkOpener.resolvesToFile(word, cwd: view?.lastKnownCwd ?? projectPath)
    }
    view.onOpenURL = { [weak view] url in
      TerminalLinkOpener.handleOpenURL(url, cwd: view?.lastKnownCwd ?? projectPath)
    }
    return tab
  }

  /// Show a surface-reported title on its tab as the running command (issue #2). The shell re-sets
  /// the title to the working directory (and `user@host:dir`) at every prompt; those would clobber
  /// the command, so they're ignored — only a real command title sticks, until `command_finished`
  /// clears it (`clearLiveTitle`). Re-storing the value-type tab in the `@Published` dict re-renders
  /// the strip; the early-out avoids redundant churn on repeated identical titles.
  private func updateTitle(_ title: String, forTab tabID: TerminalTab.ID, target: TerminalTarget.ID)
  {
    guard var tabs = tabsByTarget[target], let i = tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !Self.isDirectoryTitle(trimmed, cwd: tabs[i].view.lastKnownCwd) else {
      return
    }
    guard tabs[i].liveTitle != trimmed else { return }
    tabs[i].liveTitle = trimmed
    tabsByTarget[target] = tabs
  }

  /// Drop a tab's command title back to its default when the command finishes (issue #2).
  private func clearLiveTitle(forTab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    guard var tabs = tabsByTarget[target], let i = tabs.firstIndex(where: { $0.id == tabID }),
      tabs[i].liveTitle != nil
    else { return }
    tabs[i].liveTitle = nil
    tabsByTarget[target] = tabs
  }

  /// Whether `title` is just the working directory (the idle title the shell/prompt sets) rather
  /// than a running command — so the tab strip can ignore it (issue #2). Recognizes the absolute
  /// cwd, its `~`-abbreviated form, and a leading `user@host:` prompt prefix. Pure for testability.
  static func isDirectoryTitle(_ title: String, cwd: String?, home: String = NSHomeDirectory())
    -> Bool
  {
    guard let cwd, !cwd.isEmpty else { return false }
    // Strip a leading "user@host:" prefix (no spaces, and contains "@" — so real titles with a
    // colon like "make: error" aren't touched).
    var path = title
    if let colon = title.firstIndex(of: ":") {
      let prefix = title[..<colon]
      if prefix.contains("@"), !prefix.contains(" ") {
        path = String(title[title.index(after: colon)...])
      }
    }
    let tilde = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    return path == cwd || path == tilde
  }

  /// Tear down every surface in a tab (plan A1: `GhosttySurfaceView.tearDown` clears callbacks before
  /// freeing the surface, so no in-flight libghostty callback touches a dead view).
  private func teardown(_ tab: TerminalTab) {
    for pane in tab.root.leaves { pane.view.tearDown() }
  }
}
