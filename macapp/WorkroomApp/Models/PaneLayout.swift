import Foundation

/// Split-pane layout for a terminal target (issue #3).
///
/// The model is **single-layout**: a target has at most ONE split at a time, plus solo tabs. A tab is
/// always its own entry in the shared strip (1:1 with a `GhosttySurfaceView`); a "split" just shows
/// several tabs together as panes. So a `PaneLayout` leaf REFERENCES a tab by id — it does not own the
/// surface (the tab does). That keeps this a pure value tree: `Equatable`, and unit-testable with no
/// AppKit/libghostty in sight.
///
/// ```
///   split(h, 0.5, leaf(B), split(v, 0.6, leaf(C), leaf(D)))
///
///   ┌─────────┬───────────────┐      tabIDs == [B, C, D]   (left→right / top→bottom)
///   │         │      C         │      firstTabID == B
///   │    B    ├───────────────┤      a lone tab is NOT a PaneLayout — it's just "no split".
///   │         │      D         │      Split nodes carry a stable `id` so a divider can address
///   └─────────┴───────────────┘      exactly one node when the user drags it (resize).
/// ```
///
/// All structural edits go through the pure transforms below (`inserting` / `removingLeaf` /
/// `settingRatio`); `TerminalSessions` never walks the tree inline (DRY).
enum SplitOrientation: Equatable {
  case horizontal  // panes side by side — a vertical divider   (⌘D "split right")
  case vertical  // panes stacked    — a horizontal divider (⇧⌘D "split down")
}

/// Which edge of a pane a tab was dropped on (drag-to-split, issue #3). Resolves to the split
/// orientation and which side the dropped tab lands on.
enum PaneEdge {
  case top, right, bottom, left

  var orientation: SplitOrientation { self == .left || self == .right ? .horizontal : .vertical }
  /// True when the dropped tab should become the leading/top child (a left or top drop).
  var placesDroppedFirst: Bool { self == .left || self == .top }
}

indirect enum PaneLayout: Equatable {
  case leaf(TerminalTab.ID)
  case split(
    id: UUID, orientation: SplitOrientation, ratio: CGFloat, first: PaneLayout, second: PaneLayout)

  /// Tab ids in reading order (left→right / top→bottom). Always non-empty; the strip renders the
  /// split's members as this contiguous run.
  var tabIDs: [TerminalTab.ID] {
    switch self {
    case .leaf(let id):
      return [id]
    case .split(_, _, _, let first, let second):
      return first.tabIDs + second.tabIDs
    }
  }

  /// The first leaf in reading order. Safe: every node has ≥1 leaf.
  var firstTabID: TerminalTab.ID { tabIDs[0] }

  func contains(_ id: TerminalTab.ID) -> Bool { tabIDs.contains(id) }

  // MARK: Pure transforms

  /// Replace `.leaf(beside)` with a new split of `beside` and `newLeaf` in `orientation`. `newLeafFirst`
  /// puts the new pane on the leading/top side (a left/up drop); otherwise trailing/bottom (right/down).
  /// `ratio` is the leading child's fraction. Returns the tree unchanged if `beside` isn't a leaf here
  /// (defensive — callers pass a leaf they located).
  func inserting(
    _ newLeaf: TerminalTab.ID, beside: TerminalTab.ID, orientation: SplitOrientation,
    newLeafFirst: Bool, ratio: CGFloat
  ) -> PaneLayout {
    switch self {
    case .leaf(let id):
      guard id == beside else { return self }
      let existing = PaneLayout.leaf(id)
      let added = PaneLayout.leaf(newLeaf)
      return .split(
        id: UUID(), orientation: orientation, ratio: ratio,
        first: newLeafFirst ? added : existing,
        second: newLeafFirst ? existing : added)
    case .split(let sid, let o, let r, let first, let second):
      return .split(
        id: sid, orientation: o, ratio: r,
        first: first.inserting(
          newLeaf, beside: beside, orientation: orientation, newLeafFirst: newLeafFirst, ratio: ratio),
        second: second.inserting(
          newLeaf, beside: beside, orientation: orientation, newLeafFirst: newLeafFirst, ratio: ratio))
    }
  }

  /// Remove `id` and collapse its parent split to the surviving sibling subtree (its ratio drops out).
  /// Returns the collapsed tree — which may be a single `.leaf` when a two-pane split loses one member
  /// (the caller then dissolves the split: a lone tab is "no split"). Returns `nil` only when the whole
  /// (sub)tree WAS `.leaf(id)`. Returns the tree unchanged if `id` isn't present.
  func removingLeaf(_ id: TerminalTab.ID) -> PaneLayout? {
    switch self {
    case .leaf(let leafID):
      return leafID == id ? nil : self
    case .split(let sid, let o, let r, let first, let second):
      guard contains(id) else { return self }
      if let newFirst = first.removingLeaf(id) {
        guard let newSecond = second.removingLeaf(id) else { return newFirst }
        return .split(id: sid, orientation: o, ratio: r, first: newFirst, second: newSecond)
      }
      // `first` was (or collapsed to) nothing — promote the sibling.
      return second.removingLeaf(id) ?? second
    }
  }

  /// Set the divider fraction of the split node with `splitID`. No-op if not found. The view owns the
  /// usable clamp (min-pane is a points concern); this stores the value with only a sanity bound.
  func settingRatio(_ ratio: CGFloat, forSplit splitID: UUID) -> PaneLayout {
    switch self {
    case .leaf:
      return self
    case .split(let sid, let o, let r, let first, let second):
      if sid == splitID {
        return .split(
          id: sid, orientation: o, ratio: Self.sanitize(ratio), first: first, second: second)
      }
      return .split(
        id: sid, orientation: o, ratio: r,
        first: first.settingRatio(ratio, forSplit: splitID),
        second: second.settingRatio(ratio, forSplit: splitID))
    }
  }

  /// Keep a stored ratio strictly inside (0, 1) so a node can never be exactly collapsed in the model;
  /// the renderer applies the real min-pane (points-based) clamp on top.
  static func sanitize(_ ratio: CGFloat) -> CGFloat { min(0.999, max(0.001, ratio)) }
}
