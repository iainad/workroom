import AppKit
import SwiftTerm

/// One terminal tab: a live shell view plus a stable id and title for the tab strip.
struct TerminalTab: Identifiable {
  let id = UUID()
  let view: LocalProcessTerminalView
  let title: String
}

/// Owns the live terminals for each target (a workroom or a project root) — one or more
/// tabs each — for the lifetime of the app session, so switching targets or tabs hides/shows
/// terminals instead of tearing them down (a running dev server in one tab survives while
/// you look at another). Keyed on `TerminalTarget.ID`, which is project-scoped, so two
/// same-named workrooms in different projects (and roots) never share a terminal.
/// Cross-relaunch disk persistence is intentionally out of scope.
@MainActor
final class TerminalSessions: ObservableObject {
  @Published private var tabsByTarget: [TerminalTarget.ID: [TerminalTab]] = [:]
  @Published private var activeByTarget: [TerminalTarget.ID: TerminalTab.ID] = [:]
  /// Per-target running counter so tab titles ("Terminal 1", "2", …) stay stable across
  /// closes rather than renumbering.
  private var counts: [TerminalTarget.ID: Int] = [:]

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

  /// Create the target's first terminal the first time its pane appears. Once it has been
  /// opened, an emptied tab set is left as-is (the user closed them on purpose).
  func ensureTab(for target: TerminalTarget) {
    if tabsByTarget[target.id] == nil {
      addTab(for: target)
    }
  }

  func addTab(for target: TerminalTarget) {
    let count = (counts[target.id] ?? 0) + 1
    counts[target.id] = count
    let tab = TerminalTab(view: makeTerminal(for: target), title: "Terminal \(count)")
    tabsByTarget[target.id, default: []].append(tab)
    activeByTarget[target.id] = tab.id
  }

  func select(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    activeByTarget[target.id] = tabID
  }

  /// Reorder (drag-and-drop in the tab bar): move the dragged tab to `index` in the tab
  /// order. `index` is interpreted against the array *after* the dragged tab is removed,
  /// and is clamped to bounds. The active tab is unaffected.
  func moveTab(_ draggedID: TerminalTab.ID, toIndex index: Int, for target: TerminalTarget) {
    guard var tabs = tabsByTarget[target.id],
      let from = tabs.firstIndex(where: { $0.id == draggedID })
    else { return }
    let moved = tabs.remove(at: from)
    tabs.insert(moved, at: max(0, min(index, tabs.count)))
    tabsByTarget[target.id] = tabs
  }

  /// Close a tab. Closing the last one leaves the target with no terminals — the tab bar
  /// (and its add button) stays, and the active tab becomes nil.
  func closeTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard var tabs = tabsByTarget[target.id],
      let idx = tabs.firstIndex(where: { $0.id == tabID })
    else { return }
    let removed = tabs.remove(at: idx)
    terminate(removed.view)
    tabsByTarget[target.id] = tabs
    if activeByTarget[target.id] == tabID {
      // Activate the neighbour that slid into this slot, else the new last tab
      // (nil when none remain).
      activeByTarget[target.id] = (idx < tabs.count ? tabs[idx] : tabs.last)?.id
    }
  }

  /// Terminate and forget every terminal for a target (on delete / when its directory
  /// disappears) so we don't leak login shells.
  func reap(_ id: TerminalTarget.ID) {
    for tab in tabsByTarget[id] ?? [] { terminate(tab.view) }
    tabsByTarget[id] = nil
    activeByTarget[id] = nil
    counts[id] = nil
  }

  func reapAll() {
    for id in Array(tabsByTarget.keys) { reap(id) }
  }

  private func makeTerminal(for target: TerminalTarget) -> LocalProcessTerminalView {
    let term = LocalProcessTerminalView(frame: .zero)

    let shell = ShellEnvironment.loginShell()
    let shellName = (shell as NSString).lastPathComponent
    var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
    env.append("PATH=\(ShellEnvironment.path())")

    // `currentDirectory:` is present in the pinned SwiftTerm (v1.13.0).
    term.startProcess(
      executable: shell,
      args: ["-l"],
      environment: env,
      execName: "-\(shellName)",
      currentDirectory: target.path
    )
    return term
  }

  private func terminate(_ term: LocalProcessTerminalView) {
    // SwiftTerm v1.13.0 exposes the child via `process`; terminate() sends SIGTERM to
    // the shell so we don't leak login shells on switch / close / delete / quit.
    if term.process?.running == true {
      term.process?.terminate()
    }
    term.removeFromSuperview()
  }
}
