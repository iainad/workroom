import Foundation

/// Split-ready terminal layout (plan A5). A tab's content is a tree of panes: today always a single
/// `.leaf`, so behavior matches the pre-libghostty single-terminal-per-tab model. The future splits
/// feature adds `.split` nodes (libghostty already supports splits at the surface level); building
/// the tree now means that feature is an incremental change, not a second rewrite of the host +
/// occlusion + sessions.
enum SplitOrientation {
  case horizontal  // panes side by side (a vertical divider)
  case vertical  // panes stacked (a horizontal divider)
}

/// One leaf of a tab's pane tree: a terminal surface view with a stable id.
final class TerminalPane: Identifiable {
  let id = UUID()
  let view: GhosttySurfaceView

  init(view: GhosttySurfaceView) {
    self.view = view
  }
}

/// A tab's layout tree. Single `.leaf` today; `.split` is reserved for the splits feature (A5).
indirect enum PaneNode {
  case leaf(TerminalPane)
  case split(orientation: SplitOrientation, ratio: CGFloat, first: PaneNode, second: PaneNode)

  /// All terminal panes in this subtree, left-to-right / top-to-bottom. Always non-empty.
  var leaves: [TerminalPane] {
    switch self {
    case .leaf(let pane):
      return [pane]
    case .split(_, _, let first, let second):
      return first.leaves + second.leaves
    }
  }

  /// The first (and, today, only) leaf. Safe: every node contains at least one leaf.
  var firstLeaf: TerminalPane { leaves[0] }
}
