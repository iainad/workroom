import AppKit

/// One terminal tab: a stable id, the single surface it owns, and the strip title. With splits (issue
/// #3) a tab is still exactly one surface — a "split" composes several tabs into one on-screen layout
/// (see `PaneLayout`), it does not nest surfaces inside a tab. `TerminalTab` stays a value type on
/// purpose: live-title updates mutate a copy and reassign the dict, which is what drives `@Published`
/// (a reference type would not). The surface is a shared reference the tab owns; `teardown(_:)` frees it.
struct TerminalTab: Identifiable {
  let id = UUID()
  /// The 1:1 terminal surface this tab owns.
  let view: GhosttySurfaceView
  /// Shown until the surface reports a title — and again whenever it reports an empty one.
  let defaultTitle: String
  /// The surface's latest non-empty title (OSC 0/2 via shell integration): the running command while
  /// busy, the working directory when idle. Nil until the first report (issue #2).
  var liveTitle: String?

  /// What the tab strip displays.
  var title: String { liveTitle ?? defaultTitle }

  /// Whether a command is currently running in this terminal (issue #28) — a live command title is set
  /// while busy and cleared at the prompt. Drives the chip underline and the sidebar spinner.
  var isRunning: Bool { liveTitle != nil }
}

/// Owns the live terminals for each target (a workroom or a project root) for the app session, so
/// switching targets/tabs hides/shows terminals instead of tearing them down (a dev server in one tab
/// keeps running while you look at another). Keyed on the project-scoped `TerminalTarget.ID`.
///
/// Split model (issue #3) is **single-layout**: per target there is at most ONE `PaneLayout` split (a
/// tree of ≥2 tab ids) plus solo tabs. The content area shows the split when the focused tab belongs to
/// it, otherwise the focused solo tab. The shared tab strip lists every tab; the split's members render
/// as a contiguous bracketed run, ordered by the split tree (`displayedTabIDs`). Cross-relaunch disk
/// persistence is intentionally out of scope.
///
/// ```
///   STRIP:  A  [ B │ C ]  D        focused == C, C ∈ split  →  CONTENT renders the split.
///              └ bracket ┘         focused == A (solo)      →  CONTENT renders just A; split hidden.
/// ```
@MainActor
final class TerminalSessions: ObservableObject {
  /// Every tab for a target, by id — the single source of truth for surfaces/titles.
  @Published private var tabsByTarget: [TerminalTarget.ID: [TerminalTab.ID: TerminalTab]] = [:]
  /// The strip order (loose). The displayed order normalises this so the split's members are a
  /// contiguous run in split-tree order — see `displayedTabIDs`.
  @Published private var orderByTarget: [TerminalTarget.ID: [TerminalTab.ID]] = [:]
  /// The one split layout per target, if any (always ≥2 leaves; a lone tab is "no split").
  @Published private var splitByTarget: [TerminalTarget.ID: PaneLayout] = [:]
  /// The focused/selected tab per target. Selection = this tab (+ its split, if it's a member).
  @Published private var focusedTabByTarget: [TerminalTarget.ID: TerminalTab.ID] = [:]
  /// Bumped when a *visible but non-focused* pane reports activity (D3): the renderer flashes that
  /// pane's border instead of badging it (you can see it, so no banner/badge — just a glance cue).
  /// Keyed by tab id; the value is an opaque counter the leaf view watches for changes.
  @Published private(set) var activityPulses: [TerminalTab.ID: Int] = [:]
  /// Per-target running counter so tab titles ("Terminal 1", "2", …) stay stable across closes.
  private var counts: [TerminalTarget.ID: Int] = [:]
  /// Set once by `AppStore`: forwards each terminal's notification-worthy activity (OSC) up to the
  /// notification spine. A closure (not a store reference) so sessions stay ignorant of `AppStore`.
  var activityHandler: ((TerminalTarget.ID, TerminalTab.ID, TerminalActivity) -> Void)?

  /// Factory seam (plan T1): how a surface view is created for a target at a working directory.
  /// Overridable in tests so the lifecycle can be exercised without a real window/shell. The cwd
  /// argument lets a ⌘D split inherit the focused pane's directory.
  var makeView: (TerminalTarget, String) -> GhosttySurfaceView = { _, cwd in
    GhosttySurfaceView(workingDirectory: cwd)
  }

  /// Smallest usable pane edge (points). A split is refused when it would shrink a pane below this; the
  /// renderer applies the same minimum as its divider clamp.
  static let minPaneSize: CGFloat = 120
  /// Divider track thickness (points), shared by the fit guard and the renderer.
  static let dividerThickness: CGFloat = 7

  private var appearanceObserver: NSObjectProtocol?

  init() {
    appearanceObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil,
      queue: .main
    ) { [weak self] _ in
      DispatchQueue.main.async { self?.applyThemeToAll() }
    }
  }

  deinit {
    if let appearanceObserver {
      DistributedNotificationCenter.default().removeObserver(appearanceObserver)
    }
  }

  // MARK: Queries

  /// Tab ids in strip order: the loose order, with the split's members replaced by the split tree's
  /// order as a contiguous block at the earliest member's slot. So the bracket is always one run and
  /// strip order always matches pane order (rearranging panes IS strip reorder).
  func displayedTabIDs(for target: TerminalTarget) -> [TerminalTab.ID] {
    let order = orderByTarget[target.id] ?? []
    guard let split = splitByTarget[target.id] else { return order }
    let members = split.tabIDs
    let memberSet = Set(members)
    guard let anchor = order.firstIndex(where: { memberSet.contains($0) }) else { return order }
    var result: [TerminalTab.ID] = []
    for (i, id) in order.enumerated() {
      if i == anchor { result.append(contentsOf: members) }
      if !memberSet.contains(id) { result.append(id) }
    }
    return result
  }

  func tabs(for target: TerminalTarget) -> [TerminalTab] {
    let dict = tabsByTarget[target.id] ?? [:]
    return displayedTabIDs(for: target).compactMap { dict[$0] }
  }

  /// Whether any terminal in this target is mid-command (has a live command title, issue #2) — drives
  /// the sidebar's running spinner.
  func isRunning(forTargetID id: TerminalTarget.ID) -> Bool {
    (tabsByTarget[id] ?? [:]).values.contains { $0.isRunning }
  }

  /// The target's split layout, if a split currently exists.
  func split(for target: TerminalTarget) -> PaneLayout? { splitByTarget[target.id] }

  /// Look up a tab by id (the pane renderer resolves leaves → surfaces through this).
  func tab(_ id: TerminalTab.ID, for target: TerminalTarget) -> TerminalTab? {
    tabsByTarget[target.id]?[id]
  }

  /// The focused tab (selection), falling back to the first tab in strip order.
  func focusedTab(for target: TerminalTarget) -> TerminalTab? {
    let dict = tabsByTarget[target.id] ?? [:]
    if let id = focusedTabByTarget[target.id], let match = dict[id] { return match }
    return displayedTabIDs(for: target).first.flatMap { dict[$0] }
  }

  /// Alias kept so existing call sites/tests read naturally. "The active tab" is the focused pane.
  func activeTab(for target: TerminalTarget) -> TerminalTab? { focusedTab(for: target) }

  /// Whether the content area should render the split (the focused tab belongs to it) vs a solo tab.
  func isSplitVisible(for target: TerminalTarget) -> Bool {
    guard let split = splitByTarget[target.id], let focused = focusedTabByTarget[target.id] else {
      return false
    }
    return split.contains(focused)
  }

  /// The tab ids currently on screen: the split's members when the split is visible, else the focused
  /// solo tab. Drives occlusion.
  func visibleTabIDs(for target: TerminalTarget) -> [TerminalTab.ID] {
    if isSplitVisible(for: target), let split = splitByTarget[target.id] { return split.tabIDs }
    if let focused = focusedTab(for: target) { return [focused.id] }
    return []
  }

  // MARK: Lifecycle

  /// Create the target's first terminal the first time its pane appears. Once opened, an emptied tab
  /// set is left as-is (the user closed them on purpose).
  func ensureTab(for target: TerminalTarget) {
    if orderByTarget[target.id] == nil { addTab(for: target) }
  }

  /// Open a new solo terminal at the end of the strip and focus it (⌘T). Does not touch the split.
  @discardableResult
  func addTab(for target: TerminalTarget) -> TerminalTab {
    let tab = makeTab(for: target, cwd: target.path)
    insert(tab, for: target)
    focusedTabByTarget[target.id] = tab.id
    reconcileOcclusion(for: target)
    return tab
  }

  /// Split the focused pane by spawning a new terminal beside it (⌘D = .horizontal, ⇧⌘D = .vertical),
  /// inheriting the focused pane's working directory. No-op (refused) if the focused pane is already too
  /// small to halve (D4). If the focused tab is solo, any existing split is dissolved first — at most
  /// one split exists at a time.
  func splitFocusedPane(for target: TerminalTarget, orientation: SplitOrientation) {
    guard let focused = focusedTab(for: target) else { return }
    guard fits(splitting: focused.view, orientation: orientation) else { return }

    let cwd = focused.view.lastKnownCwd ?? target.path
    let newTab = makeTab(for: target, cwd: cwd)
    tabsByTarget[target.id, default: [:]][newTab.id] = newTab

    if let existing = splitByTarget[target.id], existing.contains(focused.id) {
      // Grow the existing split beside the focused leaf.
      splitByTarget[target.id] = existing.inserting(
        newTab.id, beside: focused.id, orientation: orientation, newLeafFirst: false, ratio: 0.5)
    } else {
      // Start a fresh split from the focused solo tab; dissolve any other split.
      splitByTarget[target.id] = .split(
        id: UUID(), orientation: orientation, ratio: 0.5,
        first: .leaf(focused.id), second: .leaf(newTab.id))
    }
    // Place the new tab right after the focused one in the loose order (display normalises anyway).
    insertID(newTab.id, after: focused.id, for: target)
    focusedTabByTarget[target.id] = newTab.id
    reconcileOcclusion(for: target)
  }

  /// Drag-and-drop (issue #3): place `movedID` on `edge` of `destID`'s pane. One op covers both
  /// dragging a tab from the strip into a pane AND rearranging an existing pane, since panes are tabs.
  /// Maintains the single-split invariant (starting a split from two solo tabs dissolves any other).
  /// No-op if either tab is missing or `movedID == destID`.
  func moveTabIntoSplit(
    _ movedID: TerminalTab.ID, ontoEdge edge: PaneEdge, of destID: TerminalTab.ID,
    for target: TerminalTarget
  ) {
    guard movedID != destID, tabsByTarget[target.id]?[movedID] != nil,
      tabsByTarget[target.id]?[destID] != nil
    else { return }

    // Base = the current split with `movedID` removed if it was in it; else the existing split when it
    // holds `destID`; else just the destination leaf (a fresh split, dissolving any unrelated one).
    let base: PaneLayout
    if let split = splitByTarget[target.id], split.contains(movedID) {
      base = split.removingLeaf(movedID) ?? .leaf(destID)
    } else if let split = splitByTarget[target.id], split.contains(destID) {
      base = split
    } else {
      base = .leaf(destID)
    }

    if base.contains(destID) {
      splitByTarget[target.id] = base.inserting(
        movedID, beside: destID, orientation: edge.orientation,
        newLeafFirst: edge.placesDroppedFirst, ratio: 0.5)
    } else {
      let dropped = PaneLayout.leaf(movedID)
      let anchor = PaneLayout.leaf(destID)
      splitByTarget[target.id] = .split(
        id: UUID(), orientation: edge.orientation, ratio: 0.5,
        first: edge.placesDroppedFirst ? dropped : anchor,
        second: edge.placesDroppedFirst ? anchor : dropped)
    }
    insertID(movedID, after: destID, for: target)  // display normalises the contiguous run
    focusedTabByTarget[target.id] = movedID
    reconcileOcclusion(for: target)
  }

  /// Pull a tab out of the split so it's a solo terminal again (drag a chip clear of the group). The
  /// split dissolves if only one member would remain. No-op if the tab isn't in a split.
  func extractFromSplit(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let split = splitByTarget[target.id], split.contains(tabID) else { return }
    if let collapsed = split.removingLeaf(tabID), collapsed.tabIDs.count >= 2 {
      splitByTarget[target.id] = collapsed
    } else {
      splitByTarget[target.id] = nil
    }
    focusedTabByTarget[target.id] = tabID  // show the extracted tab on its own
    reconcileOcclusion(for: target)
  }

  /// Focus a tab (and, if it's a split member, show the split). Single entry point: chip tap, ⌘1–9,
  /// notification routing, neighbour-after-close. `select` is an alias kept for existing call sites.
  func focus(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard tabsByTarget[target.id]?[tabID] != nil else { return }
    guard focusedTabByTarget[target.id] != tabID else { return }
    focusedTabByTarget[target.id] = tabID
    reconcileOcclusion(for: target)
  }

  func select(_ tabID: TerminalTab.ID, for target: TerminalTarget) { focus(tabID, for: target) }

  /// Reorder (drag-and-drop in the tab bar): move the dragged tab to `index` in the loose strip order,
  /// clamped to bounds. Display normalisation keeps the split's run contiguous regardless.
  func moveTab(_ draggedID: TerminalTab.ID, toIndex index: Int, for target: TerminalTarget) {
    guard var order = orderByTarget[target.id],
      let from = order.firstIndex(of: draggedID)
    else { return }
    order.remove(at: from)
    order.insert(draggedID, at: max(0, min(index, order.count)))
    orderByTarget[target.id] = order
  }

  /// Set the divider ratio of one split node (the view clamps to the points-based minimum first).
  func setRatio(_ ratio: CGFloat, forSplit splitID: UUID, for target: TerminalTarget) {
    guard let split = splitByTarget[target.id] else { return }
    splitByTarget[target.id] = split.settingRatio(ratio, forSplit: splitID)
  }

  /// Close a tab. If it's a split member the split collapses to the surviving sibling subtree (and
  /// dissolves when only one member would remain). Closing the last tab leaves the target with none.
  func closeTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let tab = tabsByTarget[target.id]?[tabID] else { return }
    let wasFocused = focusedTabByTarget[target.id] == tabID

    // Compute the focus successor BEFORE mutating, using the on-screen order.
    let successor = closeSuccessor(of: tabID, for: target)

    teardown(tab)
    tabsByTarget[target.id]?[tabID] = nil
    orderByTarget[target.id]?.removeAll { $0 == tabID }
    activityPulses[tabID] = nil

    if let split = splitByTarget[target.id], split.contains(tabID) {
      if let collapsed = split.removingLeaf(tabID), collapsed.tabIDs.count >= 2 {
        splitByTarget[target.id] = collapsed
      } else {
        splitByTarget[target.id] = nil  // dropped to a lone tab — no split anymore
      }
    }

    if wasFocused { focusedTabByTarget[target.id] = successor }
    reconcileOcclusion(for: target)
  }

  /// Terminate and forget every terminal for a target (on delete / when its directory disappears).
  func reap(_ id: TerminalTarget.ID) {
    for tab in (tabsByTarget[id] ?? [:]).values {
      teardown(tab)
      activityPulses[tab.id] = nil
    }
    tabsByTarget[id] = nil
    orderByTarget[id] = nil
    splitByTarget[id] = nil
    focusedTabByTarget[id] = nil
    counts[id] = nil
  }

  func reapAll() {
    for id in Array(tabsByTarget.keys) { reap(id) }
  }

  /// Re-theme every live terminal — visible and hidden, solo and split alike — to the current
  /// appearance. Driven from `RootView.applyAppearance()` and the system-appearance observer.
  func applyThemeToAll() {
    let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    GhosttyApp.shared.reloadConfig()
    GhosttyApp.shared.setColorScheme(dark: isDark)
    let config = GhosttyApp.shared.config
    for tabs in tabsByTarget.values {
      for tab in tabs.values {
        if let config { tab.view.updateConfig(config) }
        tab.view.applyColorScheme(isDark: isDark)
      }
    }
  }

  // MARK: Occlusion (A4 / issue #3)

  /// One reconciliation pass: exactly the on-screen tabs render; every other surface for the target is
  /// paused (its shell keeps running — `setVisible(false)` toggles GPU occlusion, not the PTY). Called
  /// from every state change that can alter what's on screen (focus / split / close / move / reap).
  func reconcileOcclusion(for target: TerminalTarget) {
    let visible = Set(visibleTabIDs(for: target))
    for tab in (tabsByTarget[target.id] ?? [:]).values {
      tab.view.setVisible(visible.contains(tab.id))
    }
  }

  /// Flash a visible non-focused pane's border to acknowledge activity without a banner/badge (D3).
  /// Driven from `AppStore.handleActivity`.
  func pulsePaneActivity(_ tabID: TerminalTab.ID) {
    activityPulses[tabID, default: 0] += 1
  }

  // MARK: Live titles (issue #2)

  /// Show a surface-reported command title on its tab; directory/prompt titles are ignored so the
  /// command sticks until `command_finished` clears it.
  private func updateTitle(_ title: String, forTab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    guard var tab = tabsByTarget[target]?[tabID] else { return }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !Self.isDirectoryTitle(trimmed, cwd: tab.view.lastKnownCwd) else { return }
    guard tab.liveTitle != trimmed else { return }
    tab.liveTitle = trimmed
    tabsByTarget[target]?[tabID] = tab
  }

  private func clearLiveTitle(forTab tabID: TerminalTab.ID, target: TerminalTarget.ID) {
    guard var tab = tabsByTarget[target]?[tabID], tab.liveTitle != nil else { return }
    tab.liveTitle = nil
    tabsByTarget[target]?[tabID] = tab
  }

  /// Whether `title` is just the working directory (the idle title the shell/prompt sets) rather than a
  /// running command — so the tab strip can ignore it (issue #2). Pure for testability.
  static func isDirectoryTitle(_ title: String, cwd: String?, home: String = NSHomeDirectory())
    -> Bool
  {
    guard let cwd, !cwd.isEmpty else { return false }
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

  // MARK: Internals

  /// Whether splitting `view` in `orientation` would leave both halves ≥ `minPaneSize` (D4). When the
  /// pane has no laid-out size yet (e.g. in tests, or before first layout) the guard can't evaluate, so
  /// it permits the split and lets the renderer's clamp handle sizing.
  private func fits(splitting view: GhosttySurfaceView, orientation: SplitOrientation) -> Bool {
    let available = orientation == .horizontal ? view.bounds.width : view.bounds.height
    guard available > 0 else { return true }
    return (available - Self.dividerThickness) / 2 >= Self.minPaneSize
  }

  /// The tab to focus after `tabID` is closed: the on-screen neighbour that slides into its slot, else
  /// the new last on-screen tab, else nil.
  private func closeSuccessor(of tabID: TerminalTab.ID, for target: TerminalTarget) -> TerminalTab.ID?
  {
    let order = displayedTabIDs(for: target)
    guard let idx = order.firstIndex(of: tabID) else { return order.first { $0 != tabID } }
    let remaining = order.filter { $0 != tabID }
    guard !remaining.isEmpty else { return nil }
    return remaining[min(idx, remaining.count - 1)]
  }

  private func insert(_ tab: TerminalTab, for target: TerminalTarget) {
    tabsByTarget[target.id, default: [:]][tab.id] = tab
    orderByTarget[target.id, default: []].append(tab.id)
  }

  private func insertID(_ id: TerminalTab.ID, after other: TerminalTab.ID, for target: TerminalTarget)
  {
    var order = orderByTarget[target.id] ?? []
    order.removeAll { $0 == id }
    if let i = order.firstIndex(of: other) {
      order.insert(id, at: i + 1)
    } else {
      order.append(id)
    }
    orderByTarget[target.id] = order
  }

  private func makeTab(for target: TerminalTarget, cwd: String) -> TerminalTab {
    let count = (counts[target.id] ?? 0) + 1
    counts[target.id] = count
    let view = makeView(target, cwd)
    let tab = TerminalTab(view: view, defaultTitle: "Terminal \(count)")

    let targetID = target.id
    let tabID = tab.id
    view.onActivity = { [weak self] activity in
      self?.activityHandler?(targetID, tabID, activity)
    }
    view.onTitleChange = { [weak self] title in
      self?.updateTitle(title, forTab: tabID, target: targetID)
    }
    view.onCommandFinished = { [weak self] in
      self?.clearLiveTitle(forTab: tabID, target: targetID)
    }
    // A pane became first responder (click / programmatic focus): make it the selection (issue #3).
    view.onFocused = { [weak self] in
      guard let self, let target = self.target(forID: targetID) else { return }
      self.focus(tabID, for: target)
    }

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

  /// Reconstruct a minimal `TerminalTarget` from its id for the `onFocused` callback (which only
  /// carries ids). `focus` keys off the id alone, so a minimal target is sufficient.
  private func target(forID id: TerminalTarget.ID) -> TerminalTarget? {
    guard tabsByTarget[id] != nil else { return nil }
    return TerminalTarget(id: id, title: "", path: "", isMissing: false)
  }

  /// Tear down a tab's surface (clears callbacks before freeing, so no in-flight libghostty callback
  /// touches a dead view).
  private func teardown(_ tab: TerminalTab) { tab.view.tearDown() }
}
