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

  /// Whether a real (≥2 live members) workroom split is active — drives `RootView`'s render branch.
  var workroomSplitActive: Bool { resolvedSplitLeaves() != nil }

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
    guard sid != beside, target(for: sid) != nil, target(for: beside) != nil else { return }
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

  /// Tear down the split, showing the single focused workroom. Used by the "click a non-member bar tab"
  /// path (selection then dissolves the co-display) and by the bar-off case. Selection is left to the caller.
  func dissolveWorkroomSplit() { workroomSplit = nil }

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
