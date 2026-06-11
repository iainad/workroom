import CoreGraphics

/// Pure drag-to-reorder math, shared by the terminal tab strip (`TerminalTabStrip`) and the
/// Workrooms tab bar (`WorkroomTabBar`, issue #23). Lifted out of `TerminalTabStrip` so the index
/// resolution and gap offsets are unit-testable without a view, and the two strips can't drift.
///
/// Operates on **position-indexed** chip widths (`widths[i]` is the natural width of the chip at
/// position `i`), so it's agnostic to what the chips are — terminal tabs (`UUID`) or workroom
/// targets (`String`). The caller maps its own model to a `[CGFloat]` before calling.
enum TabReorder {
  /// Where the dragged chip lands given its current translation: walk outward from `draggedIndex`,
  /// crossing each neighbour once the drag passes that neighbour's half-width (chip width +
  /// `spacing`). Reaches index 0 and the last slot.
  static func dropTargetIndex(
    widths: [CGFloat], draggedIndex di: Int, translation: CGFloat, spacing: CGFloat
  ) -> Int {
    var idx = di
    if translation > 0 {
      var accumulated: CGFloat = 0
      var j = di + 1
      while j < widths.count {
        let span = widths[j] + spacing
        if translation > accumulated + span / 2 {
          idx = j
          accumulated += span
          j += 1
        } else {
          break
        }
      }
    } else if translation < 0 {
      var accumulated: CGFloat = 0
      var j = di - 1
      while j >= 0 {
        let span = widths[j] + spacing
        if -translation > accumulated + span / 2 {
          idx = j
          accumulated += span
          j -= 1
        } else {
          break
        }
      }
    }
    return idx
  }

  /// Horizontal shift for a non-dragged chip at `index` so the row opens a gap at the drop `target`.
  /// `amount` is the dragged chip's width plus inter-chip spacing.
  static func gapShift(index: Int, draggedIndex: Int?, target: Int?, amount: CGFloat) -> CGFloat {
    guard let di = draggedIndex, let ti = target else { return 0 }
    if di < ti, index > di, index <= ti { return -amount }  // dragging right: slide left
    if di > ti, index >= ti, index < di { return amount }  // dragging left: slide right
    return 0
  }
}
