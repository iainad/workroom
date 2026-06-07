import AppKit
import SwiftUI

/// Renders a target's pane layout (issue #3): a solo terminal is a single-leaf layout, a split is a
/// tree. Every visible pane is laid out in ONE flat `ZStack`, positioned by an absolutely-computed
/// frame and keyed by tab id — a surviving pane keeps the exact same host across layout changes (only
/// its frame moves), so its surface is never re-parented (the close-a-split-pane blank bug). Frame and
/// drop-target math are pure and unit-tested (plan D5).
///
/// Drag-and-drop (Phase 2): each split pane shows a small grip chip at its top-center; dragging it
/// shows 4 edge drop zones on the pane under the cursor and, on drop, moves/rearranges via
/// `moveTabIntoSplit` (or pops the pane out to solo via `extractFromSplit` if dragged up to the strip).
struct PaneTreeView: View {
  let layout: PaneLayout
  let target: TerminalTarget
  @ObservedObject var sessions: TerminalSessions
  /// A drag originating outside the tree (a strip tab chip dragged into the content), in content-local
  /// coords — rendered with the same edge preview + ghost as an in-tree pane-handle drag.
  var externalDrag: PaneDragState?

  @State private var drag: PaneDragState?
  private static let space = "paneContent"

  /// Whichever drag is active: an in-tree pane-handle drag, or an incoming chip drag.
  private var activeDrag: PaneDragState? { drag ?? externalDrag }

  var body: some View {
    let focusedID = sessions.focusedTab(for: target)?.id
    let multiPane = layout.tabIDs.count >= 2
    GeometryReader { geo in
      let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: geo.size))
      ZStack(alignment: .topLeading) {
        ForEach(layout.tabIDs, id: \.self) { tabID in
          if let tab = sessions.tab(tabID, for: target), let rect = plan.panes[tabID] {
            PaneLeafView(
              tabID: tabID, view: tab.view, sessions: sessions,
              focused: tabID == focusedID, multiPane: multiPane, coordinateSpace: Self.space,
              onDragChanged: { drag = PaneDragState(tabID: tabID, location: $0) },
              onDragEnded: { commitDrag(plan: plan) }
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .id(tabID)
          }
        }
        ForEach(plan.dividers) { d in
          SplitDivider(orientation: d.orientation, ratio: d.ratio, total: d.total) {
            sessions.setRatio($0, forSplit: d.id, for: target)
          }
          .frame(width: d.rect.width, height: d.rect.height)
          .position(x: d.rect.midX, y: d.rect.midY)
        }
        dropHighlight(plan: plan)
        dragGhost()
      }
      .coordinateSpace(.named(Self.space))
    }
  }

  /// The accent band previewing where a dragged pane will land.
  @ViewBuilder
  private func dropHighlight(plan: PaneTreeLayout.Plan) -> some View {
    if let drag = activeDrag,
      let hit = PaneTreeLayout.dropTarget(at: drag.location, panes: plan.panes),
      hit.tab != drag.tabID, let rect = plan.panes[hit.tab]
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

  /// A floating preview of the pane being dragged (its title + grip), tracking the cursor with a
  /// shadow — so it's clear what's being moved and to where.
  @ViewBuilder
  private func dragGhost() -> some View {
    if let drag = activeDrag, let tab = sessions.tab(drag.tabID, for: target) {
      HStack(spacing: 5) {
        Image(systemName: "line.3.horizontal").font(.system(size: 9, weight: .semibold))
        Text(tab.title).font(.caption).lineLimit(1)
      }
      .foregroundStyle(.primary)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
      .fixedSize()
      .position(x: drag.location.x, y: drag.location.y - 14)  // float just above the cursor
      .allowsHitTesting(false)
    }
  }

  private func commitDrag(plan: PaneTreeLayout.Plan) {
    defer { drag = nil }
    guard let drag else { return }
    if let hit = PaneTreeLayout.dropTarget(at: drag.location, panes: plan.panes),
      hit.tab != drag.tabID
    {
      sessions.moveTabIntoSplit(drag.tabID, ontoEdge: hit.edge, of: hit.tab, for: target)
    } else if drag.location.y < 0 {
      // Dragged up out of the panes (toward the strip) → pop this pane out of the split to solo.
      sessions.extractFromSplit(drag.tabID, for: target)
    }
  }
}

/// A pane drag in progress: which tab, and the cursor in the content coordinate space.
struct PaneDragState {
  let tabID: TerminalTab.ID
  var location: CGPoint
}

// MARK: - Pure layout & drop math (extracted for unit tests — plan D5)

struct PaneDividerFrame: Identifiable {
  let id: UUID
  let orientation: SplitOrientation
  let rect: CGRect
  let ratio: CGFloat
  let total: CGFloat
}

enum PaneTreeLayout {
  typealias Plan = (panes: [TerminalTab.ID: CGRect], dividers: [PaneDividerFrame])

  static var dividerThickness: CGFloat { TerminalSessions.dividerThickness }
  static var minPane: CGFloat { TerminalSessions.minPaneSize }

  /// Lengths of the first/second child along the split axis for a container of `total` points. Rounds
  /// the first child to whole points (avoids sub-pixel seams) and clamps so neither child falls below
  /// `minPane`; when the container is too small to honor that, falls back to an even split.
  static func lengths(total: CGFloat, ratio: CGFloat) -> (first: CGFloat, second: CGFloat) {
    let usable = max(0, total - dividerThickness)
    guard usable > 2 * minPane else {
      let half = (usable / 2).rounded()
      return (half, usable - half)
    }
    let raw = (usable * ratio).rounded()
    let first = min(usable - minPane, max(minPane, raw))
    return (first, usable - first)
  }

  /// Clamp a proposed divider ratio to keep both panes ≥ `minPane` (the single, view-owned clamp).
  static func clampRatio(_ ratio: CGFloat, total: CGFloat) -> CGFloat {
    let usable = max(1, total - dividerThickness)
    guard usable > 2 * minPane else { return 0.5 }
    let minR = minPane / usable
    return min(1 - minR, max(minR, ratio))
  }

  /// Absolute frames for every leaf (by tab id) and every divider, laying `node` out in `rect`.
  static func plan(_ node: PaneLayout, in rect: CGRect) -> Plan {
    switch node {
    case .leaf(let id):
      return ([id: rect], [])
    case .split(let sid, let orientation, let ratio, let first, let second):
      let axis = orientation == .horizontal ? rect.width : rect.height
      let (firstLen, secondLen) = lengths(total: axis, ratio: ratio)
      let div = dividerThickness
      let firstRect: CGRect
      let dividerRect: CGRect
      let secondRect: CGRect
      if orientation == .horizontal {
        firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstLen, height: rect.height)
        dividerRect = CGRect(x: rect.minX + firstLen, y: rect.minY, width: div, height: rect.height)
        secondRect = CGRect(
          x: rect.minX + firstLen + div, y: rect.minY, width: secondLen, height: rect.height)
      } else {
        firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLen)
        dividerRect = CGRect(x: rect.minX, y: rect.minY + firstLen, width: rect.width, height: div)
        secondRect = CGRect(
          x: rect.minX, y: rect.minY + firstLen + div, width: rect.width, height: secondLen)
      }
      let f = plan(first, in: firstRect)
      let s = plan(second, in: secondRect)
      var panes = f.panes
      panes.merge(s.panes) { a, _ in a }
      let divider = PaneDividerFrame(
        id: sid, orientation: orientation, rect: dividerRect, ratio: ratio, total: axis)
      return (panes, f.dividers + [divider] + s.dividers)
    }
  }

  /// Which pane + edge a content-local `point` targets. Each pane is tiled into 4 triangles meeting at
  /// its center, so the nearest edge always wins — no dead zone (plan: "edges tile the whole pane").
  static func dropTarget(at point: CGPoint, panes: [TerminalTab.ID: CGRect])
    -> (tab: TerminalTab.ID, edge: PaneEdge)?
  {
    guard let hit = panes.first(where: { $0.value.contains(point) }) else { return nil }
    return (hit.key, nearestEdge(of: point, in: hit.value))
  }

  /// The edge of `rect` nearest `point`, normalised by the rect's aspect (so a wide pane still splits
  /// top/bottom near its short edges).
  static func nearestEdge(of point: CGPoint, in rect: CGRect) -> PaneEdge {
    let dx = rect.width == 0 ? 0 : (point.x - rect.midX) / rect.width
    let dy = rect.height == 0 ? 0 : (point.y - rect.midY) / rect.height
    if abs(dx) >= abs(dy) { return dx < 0 ? .left : .right }
    return dy < 0 ? .top : .bottom
  }

  /// The half-pane band to highlight for a drop on `edge`.
  static func edgeBand(_ edge: PaneEdge, in rect: CGRect) -> CGRect {
    switch edge {
    case .left:
      return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .right:
      return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
    case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
    case .bottom:
      return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    }
  }
}

// MARK: - Leaf

/// One terminal pane: hosts the surface, the focus ring, the activity flash (D3), and — in a split — a
/// small semi-transparent grip chip at the top-center that you drag to move the pane. (Closing is via
/// the strip ✕ / ⌘W, so the pane needs no close affordance of its own.)
private struct PaneLeafView: View {
  let tabID: TerminalTab.ID
  let view: GhosttySurfaceView
  @ObservedObject var sessions: TerminalSessions
  let focused: Bool
  let multiPane: Bool
  let coordinateSpace: String
  let onDragChanged: (CGPoint) -> Void
  let onDragEnded: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var flashing = false
  @State private var hovering = false

  var body: some View {
    TerminalContainerView(view: view, isFocusedPane: focused)
      .overlay(
        RoundedRectangle(cornerRadius: 12)
          .strokeBorder(borderColor, lineWidth: 2)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: flashing)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: focused)
      )
      .overlay(alignment: .top) { handle }
      .padding(multiPane ? 3 : 0)
      .onHover { hovering = $0 }
      .onChange(of: sessions.activityPulses[tabID]) { _, _ in
        guard multiPane, !focused else { return }
        flashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { flashing = false }
      }
  }

  /// A small semi-transparent grip chip at the pane's top-center — drag it to move the pane (onto
  /// another pane's edge, or up to the strip to pop it out). Only in a split; faint until hovered.
  @ViewBuilder private var handle: some View {
    if multiPane {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .opacity(hovering ? 0.95 : 0.3)
        .padding(.top, 5)
        .contentShape(Capsule())
        .gesture(
          DragGesture(coordinateSpace: .named(coordinateSpace))
            .onChanged { onDragChanged($0.location) }
            .onEnded { _ in onDragEnded() }
        )
        .help("Drag to move this pane")
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
    }
  }

  private var borderColor: Color {
    guard multiPane else { return .clear }
    if focused { return Color.accentColor.opacity(0.85) }
    return flashing ? Color.accentColor.opacity(0.7) : .clear
  }
}

// MARK: - Divider

/// A draggable divider that writes a new ratio for one split node. Mirrors `ScriptLogPanel`'s resize
/// handle: an invisible but hit-testable track with a 1pt hairline and a resize cursor on hover.
private struct SplitDivider: View {
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
  }
}
