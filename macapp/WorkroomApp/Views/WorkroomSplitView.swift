import AppKit
import SwiftUI

/// A drag from the workroom tab bar into the split content (content-local point + the dragged tab's id).
struct WorkroomPaneDrag: Equatable {
  let sid: SidebarID
  var location: CGPoint
}

/// Workroom-into-workroom split renderer (issue #23 follow-up): renders `PaneLayout<SidebarID>` as
/// nested, resizable panes — each a full `TargetTerminalDetail`. Deliberately SEPARATE from the
/// terminal renderer `PaneTreeView` (whose re-parenting/blank-pane history makes surgery risky); it
/// reuses only the pure `PaneTreeLayout` geometry + the generic `PaneLayout` model and duplicates a
/// little view chrome (divider, focus border, drop band).
///
/// Like `PaneTreeView`, panes are laid out in ONE flat `ZStack`, positioned by absolute frames and
/// keyed by `SidebarID`, so a surviving pane keeps the exact same host across a layout change (only its
/// frame moves) — its terminal is never re-parented. `RootView` ALWAYS renders through this view when
/// the tab bar is on (a no-split case is just `.leaf(selected)`), so single↔split is a leaf-set change,
/// not a structural swap — the same lesson that made `WorkroomTerminalsView` always render through
/// `PaneTreeView`.
struct WorkroomSplitView: View {
  let layout: PaneLayout<SidebarID>
  /// Resolve a leaf to its live target (drops a since-deleted workroom). Owned by the store.
  let resolve: (SidebarID) -> TerminalTarget?
  let focusedID: SidebarID?
  /// A live drag from the tab bar into the content (drives the drop-edge highlight).
  var externalDrag: WorkroomPaneDrag?
  let onFocus: (SidebarID) -> Void
  let onSetRatio: (CGFloat, UUID) -> Void
  let onClose: (SidebarID) -> Void

  private static let space = "workroomSplitContent"

  var body: some View {
    let leaves = layout.tabIDs
    let multi = leaves.count >= 2
    GeometryReader { geo in
      let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: geo.size))
      ZStack(alignment: .topLeading) {
        ForEach(leaves, id: \.self) { sid in
          if let target = resolve(sid), let rect = plan.panes[sid] {
            WorkroomPaneLeaf(
              target: target, focused: sid == focusedID, multi: multi,
              onClose: { onClose(sid) }
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .id(sid)
            // A tap on the pane *chrome* focuses it. Clicking *into* the terminal is handled by the
            // first-responder → selection callback (the libghostty NSView eats SwiftUI taps).
            .onTapGesture { onFocus(sid) }
          }
        }
        ForEach(plan.dividers) { d in
          WorkroomSplitDivider(orientation: d.orientation, ratio: d.ratio, total: d.total) {
            onSetRatio($0, d.id)
          }
          .frame(width: d.rect.width, height: d.rect.height)
          .position(x: d.rect.midX, y: d.rect.midY)
        }
        dropHighlight(plan: plan)
      }
      .coordinateSpace(.named(Self.space))
    }
  }

  /// The accent band previewing where a dragged workroom tab will land (mirrors `PaneTreeView`).
  @ViewBuilder
  private func dropHighlight(plan: PaneTreeLayout.Plan<SidebarID>) -> some View {
    if let drag = externalDrag,
      let hit = PaneTreeLayout.dropTarget(at: drag.location, panes: plan.panes),
      hit.tab != drag.sid, let rect = plan.panes[hit.tab]
    {
      let band = PaneTreeLayout.edgeBand(hit.edge, in: rect)
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.accentColor.opacity(0.25))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2))
        .frame(width: band.width, height: band.height)
        .position(x: band.midX, y: band.midY)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }
}

/// One workroom pane: the full terminal body + a focus border and a hover ✕ (remove from split). Solo
/// (`multi == false`) it's just the bare `TargetTerminalDetail`, so the single-workroom case renders
/// identically to the old `targetDetail` content.
private struct WorkroomPaneLeaf: View {
  let target: TerminalTarget
  let focused: Bool
  let multi: Bool
  let onClose: () -> Void

  var body: some View {
    // The remove-from-split control rides on the tab strip's right edge (a layout sibling of the tabs,
    // so it never overlaps them) rather than as a corner overlay — forwarded via `onCloseWorkroomPane`.
    TargetTerminalDetail(target: target, onCloseWorkroomPane: multi ? onClose : nil)
      .overlay(
        RoundedRectangle(cornerRadius: 12).strokeBorder(borderColor, lineWidth: 1.5)
      )
      // Same 3pt inset as a terminal pane, so a workroom's surface sits in the same place solo or split.
      .padding(3)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("workroom.pane")
      .accessibilityLabel(Text("Workroom \(target.title)"))
      .accessibilityAddTraits(focused && multi ? .isSelected : [])
  }

  private var borderColor: Color {
    guard multi else { return .clear }
    return focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)
  }
}

/// A draggable divider that writes a new ratio for one split node. A near-twin of `PaneTreeView`'s
/// private `SplitDivider` (kept separate so the terminal renderer stays untouched), reusing the shared
/// `PaneTreeLayout.clampRatio`/`dividerThickness` math.
private struct WorkroomSplitDivider: View {
  let orientation: SplitOrientation
  let ratio: CGFloat
  let total: CGFloat
  let onRatio: (CGFloat) -> Void
  @State private var startRatio: CGFloat?

  var body: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.0001))
      .overlay(
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(
            width: orientation == .horizontal ? 1 : nil,
            height: orientation == .vertical ? 1 : nil)
      )
      .contentShape(Rectangle())
      .gesture(
        DragGesture(coordinateSpace: .global)
          .onChanged { value in
            let start = startRatio ?? ratio
            if startRatio == nil { startRatio = start }
            let usable = max(1, total - PaneTreeLayout.dividerThickness)
            let delta =
              orientation == .horizontal ? value.translation.width : value.translation.height
            onRatio(PaneTreeLayout.clampRatio(start + delta / usable, total: total))
          }
          .onEnded { _ in startRatio = nil }
      )
      .onHover { inside in
        if inside {
          (orientation == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
          NSCursor.pop()
        }
      }
      .accessibilityElement()
      .accessibilityIdentifier("workroom.pane.divider")
      .accessibilityLabel(
        orientation == .horizontal ? "Vertical workroom divider" : "Horizontal workroom divider"
      )
      .accessibilityValue("\(Int((ratio * 100).rounded()))%")
      .accessibilityAdjustableAction { direction in
        let step: CGFloat = 0.05
        switch direction {
        case .increment: onRatio(PaneTreeLayout.clampRatio(ratio + step, total: total))
        case .decrement: onRatio(PaneTreeLayout.clampRatio(ratio - step, total: total))
        @unknown default: break
        }
      }
  }
}
