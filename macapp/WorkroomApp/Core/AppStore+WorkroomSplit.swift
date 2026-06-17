import Foundation

/// Workroom-into-workroom split (issue #23 follow-up). The stored `@Published var workroomSplit` lives
/// on `AppStore`; these are the pure-ish transforms over it. They mirror `TerminalSessions`'
/// `moveTabIntoSplit` / `extractFromSplit` one level up (workrooms, not tabs), and every entry guards
/// `target(for:) != nil` — which rejects `.project` and any leaf that no longer resolves (so the model
/// can never hold an invalid workroom). The focused split member IS `selectedTargetID`.
extension AppStore {

  /// Live `(sid, target)` for each leaf in tree order, dropping leaves that no longer resolve. Returns
  /// nil when the split is absent or has <2 live members (a lone leaf is "no split"). This is the single
  /// read the renderer + the `workroomSplitActive` gate use, so a deleted workroom self-heals on read.
  func resolvedSplitLeaves() -> [(sid: SidebarID, target: TerminalTarget)]? {
    guard let split = workroomSplit else { return nil }
    let live = split.tabIDs.compactMap { sid in target(for: sid).map { (sid: sid, target: $0) } }
    return live.count >= 2 ? live : nil
  }

  /// Whether a real (≥2 live members) workroom split exists at all (regardless of what's selected) —
  /// drives the tab bar's grouping bracket.
  var workroomSplitActive: Bool { resolvedSplitLeaves() != nil }

  /// Whether the split is currently *shown*: it exists (≥2 live) AND the selected workroom is one of
  /// its members. Mirrors `TerminalSessions.isSplitVisible` — the split is persistent state; selecting
  /// a non-member shows that workroom solo without dissolving the split (it reappears on reselect).
  var isWorkroomSplitVisible: Bool {
    guard let split = workroomSplit, let sel = selectedTargetID else { return false }
    return split.contains(sel) && resolvedSplitLeaves() != nil
  }

  /// The layout the detail renders for `selected`: the split when `selected` is a member, else the
  /// workroom solo (`.leaf`). Mirrors `WorkroomTerminalsView.contentLayout`. The split is NOT discarded
  /// when a non-member is shown — `workroomSplit` persists, so reselecting a member brings it back.
  ///
  /// Prunes leaves whose workroom no longer resolves *before* returning, so the renderer never lays out
  /// a rect (and a divider-to-nowhere) for a dead pane in the frame between an out-of-band deletion and
  /// `pruneWorkroomSplitToLiveLeaves()` running in `apply(_:)`. A lone surviving leaf is "no split".
  func visibleWorkroomLayout(for selected: SidebarID) -> PaneLayout<SidebarID> {
    if let split = workroomSplit, split.contains(selected) {
      var pruned = split
      for sid in split.tabIDs where target(for: sid) == nil {
        pruned = pruned.removingLeaf(sid) ?? pruned
      }
      if pruned.contains(selected), pruned.tabIDs.count >= 2 {
        return pruned
      }
    }
    return .leaf(selected)
  }

  /// The active workroom tabs in bar order, but with the split's members pulled into a contiguous run
  /// at the earliest member's slot — so the grouped workrooms sit together and a single bracket can
  /// span them. Mirrors `TerminalSessions.displayedTabIDs`. No split ⇒ just `orderedWorkroomTargets()`.
  func displayedWorkroomTargets() -> [(sid: SidebarID, target: TerminalTarget)] {
    let ordered = orderedWorkroomTargets()
    guard let split = workroomSplit else { return ordered }
    let memberSet = Set(split.tabIDs)
    guard let anchor = ordered.firstIndex(where: { memberSet.contains($0.sid) }) else {
      return ordered
    }
    let byID = Dictionary(ordered.map { ($0.sid, $0) }, uniquingKeysWith: { a, _ in a })
    // Members present in the bar, in split (tree) order.
    let memberRun = split.tabIDs.compactMap { byID[$0] }
    var result: [(sid: SidebarID, target: TerminalTarget)] = []
    for (i, entry) in ordered.enumerated() {
      if i == anchor { result.append(contentsOf: memberRun) }
      if !memberSet.contains(entry.sid) { result.append(entry) }
    }
    return result
  }

  /// Focus a split member: this is the selection (mirrors `RootView.selectWorkroomTab`). Records nav
  /// history via `selectedTargetID.didSet` — used by *deliberate* actions (drop, remove-reselect). The
  /// incidental click-to-focus path (a surface becoming first responder) routes through a
  /// history-suppressed setter instead (see the focus callback), so co-monitoring glances don't spam ⌘[.
  func focusWorkroomMember(_ sid: SidebarID) {
    selectedTargetID = sid
    selectedProjectID = Self.projectPath(of: sid)
  }

  /// Insert `sid` beside `beside` on `edge`. Seeds a fresh 2-leaf split from `beside` if none exists;
  /// **removes `sid` first if it's already a member** so dragging an existing pane to a new edge is a
  /// *move*, not a duplicate. Focuses the inserted member. No-op for a self-drop or non-resolving leaf.
  /// Mirrors `TerminalSessions.moveTabIntoSplit`.
  func insertWorkroomSplit(_ sid: SidebarID, beside: SidebarID, edge: PaneEdge) {
    // Reject a self-drop, a non-resolving leaf (`.project` / deleted workroom), and a workroom whose
    // directory is gone (`isMissing`) — a missing leaf would render a "Directory not found" pane that
    // can only be backed out of again, so don't let one into the split in the first place (#23).
    guard sid != beside, let dropped = target(for: sid), !dropped.isMissing,
      target(for: beside) != nil
    else { return }
    let base: PaneLayout<SidebarID>
    if let split = workroomSplit, split.contains(sid) {
      base = split.removingLeaf(sid) ?? .leaf(beside)
    } else if let split = workroomSplit, split.contains(beside) {
      base = split
    } else {
      base = .leaf(beside)
    }
    if base.contains(beside) {
      workroomSplit = base.inserting(
        sid, beside: beside, orientation: edge.orientation,
        newLeafFirst: edge.placesDroppedFirst, ratio: 0.5)
    } else {
      let dropped = PaneLayout<SidebarID>.leaf(sid)
      let anchor = PaneLayout<SidebarID>.leaf(beside)
      workroomSplit = .split(
        id: UUID(), orientation: edge.orientation, ratio: 0.5,
        first: edge.placesDroppedFirst ? dropped : anchor,
        second: edge.placesDroppedFirst ? anchor : dropped)
    }
    focusWorkroomMember(sid)
  }

  /// Remove `sid` from the split: collapse to the survivor subtree, or dissolve to nil (single view)
  /// when fewer than two members remain — re-pointing `selectedTargetID` to a survivor if the removed
  /// member was focused. **Never reaps terminals** (the workroom keeps running; it just leaves the
  /// split). No-op if `sid` isn't a member. Mirrors `TerminalSessions.extractFromSplit`.
  func removeWorkroomSplitMember(_ sid: SidebarID) {
    guard let split = workroomSplit, split.contains(sid) else { return }
    if let collapsed = split.removingLeaf(sid), collapsed.tabIDs.count >= 2 {
      workroomSplit = collapsed
      if selectedTargetID == sid { focusWorkroomMember(collapsed.firstTabID) }
    } else {
      let survivor = split.removingLeaf(sid)?.firstTabID
      workroomSplit = nil
      if let survivor, selectedTargetID == sid { focusWorkroomMember(survivor) }
    }
  }

  /// When a split member's last terminal is closed, its pane has nothing left but the
  /// remove-from-split ✕ — so close it for the user: drop the now-empty workroom from the split
  /// (collapse to the survivor subtree, or dissolve to the lone survivor, re-pointing selection as
  /// needed). No-op unless the target is empty AND still resolves to a member: a *deleted* workroom is
  /// handled by `pruneWorkroomSplitToLiveLeaves`, and a solo (non-split) workroom keeps its empty
  /// "New Terminal" state (issue #55).
  func autoCloseEmptiedSplitMember(_ targetID: TerminalTarget.ID) {
    guard terminals.tabCount(forTargetID: targetID) == 0,
      let sid = Self.sidebarID(forTargetID: targetID, in: projects)
    else { return }
    removeWorkroomSplitMember(sid)  // guards `split.contains(sid)` → no-op for a non-member
  }

  /// Set a divider ratio (driven by `WorkroomSplitView`'s divider drag).
  func setWorkroomSplitRatio(_ ratio: CGFloat, forSplit splitID: UUID) {
    workroomSplit = workroomSplit?.settingRatio(ratio, forSplit: splitID)
  }

  /// Drop split leaves whose workroom no longer resolves (deleted / reloaded away), collapsing or
  /// dissolving as needed. Called from `apply(_:)` after the selection is validated, so a dissolve can
  /// re-point selection to a live survivor when the old selection was nilled out.
  func pruneWorkroomSplitToLiveLeaves() {
    guard let split = workroomSplit else { return }
    let live = split.tabIDs.filter { target(for: $0) != nil }
    guard live.count < split.tabIDs.count else { return }  // nothing dead
    if live.count >= 2 {
      var pruned = split
      for sid in split.tabIDs where target(for: sid) == nil {
        pruned = pruned.removingLeaf(sid) ?? pruned
      }
      workroomSplit = pruned
    } else {
      workroomSplit = nil
      if selectedTargetID == nil, let survivor = live.first { focusWorkroomMember(survivor) }
    }
  }
}
