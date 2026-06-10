import SwiftUI

/// The horizontal tab strip above a target's terminal: a chip per terminal tab, a "+" to open a
/// new one, and the drag interactions — reorder within the strip, or drag a chip down into a pane
/// to split (issue #3). Fully owns the reorder drag state; the drop-into-pane wiring is shared with
/// the pane content, so `WorkroomTerminalsView` passes a `chipPaneDrag` binding (the live preview the
/// pane tree renders) plus `localize`/`dropTarget` closures that resolve a cursor point against the
/// pane area (which only the coordinator knows the frame of).
struct TerminalTabStrip: View {
  let tabs: [TerminalTab]
  let activeID: TerminalTab.ID?
  let target: TerminalTarget
  @ObservedObject var sessions: TerminalSessions
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The live drop-into-pane preview, shared with `PaneTreeView` via the coordinator.
  @Binding var chipPaneDrag: PaneDragState?
  /// The pane-local point for a chip drag at a global location, or nil when the cursor is still over
  /// the strip (→ a reorder, not a drop-into-pane). Owned by the coordinator (needs the pane frame).
  let localize: (CGPoint) -> CGPoint?
  /// Where a chip dropped at a global location lands (pane + edge), or nil if it isn't over a pane.
  let dropTarget: (CGPoint) -> (tab: TerminalTab.ID, edge: PaneEdge)?

  @State private var hoveredTab: TerminalTab.ID?
  @State private var addHovering = false

  // Drag-to-reorder. The tab order is *frozen* for the duration of a drag: the dragged
  // chip simply follows the cursor (its slot never moves, so it can't jump), and the
  // other chips slide aside to open a gap. The reorder is committed once, on drop.
  @State private var draggingID: TerminalTab.ID?
  @State private var dragTranslation: CGFloat = 0
  @State private var widths: [TerminalTab.ID: CGFloat] = [:]

  private let tabSpacing: CGFloat = 4

  var body: some View {
    // Resolve the drag once per layout: which tab is dragging, and where it would land.
    let draggedIndex = draggingID.flatMap { id in tabs.firstIndex { $0.id == id } }
    // While dragging a chip down into a pane, the strip stops opening a reorder gap.
    let dropIndex =
      chipPaneDrag != nil ? nil : draggedIndex.map { dropTargetIndex(tabs, draggedIndex: $0) }
    let draggedWidth = draggingID.flatMap { widths[$0] } ?? 0

    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: tabSpacing) {
          ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
            let isDragging = draggingID == tab.id
            let isHovered = hoveredTab == tab.id && draggingID == nil
            // Activity in an unfocused tab highlights the tab itself (accent title + faint accent
            // fill) instead of a count — a tab is too narrow for a number.
            let hasActivity = notifications.count(tab: tab.id) > 0
            // Dragged chip tracks the cursor; the rest shift to open the gap.
            let offsetX =
              isDragging
              ? dragTranslation
              : gapShift(
                for: index, draggedIndex: draggedIndex, target: dropIndex,
                amount: draggedWidth + tabSpacing)
            TerminalTabChip(
              tab: tab, isActive: tab.id == activeID, isHovered: isHovered,
              isDragging: isDragging, hasActivity: hasActivity
            ) {
              store.requestCloseTerminalTab(tab.id, for: target)
            }
            .onHover { inside in
              if inside { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil }
            }
            .onTapGesture {
              // Selecting changes `active.id`; the view's .onChange hook marks the tab read.
              sessions.select(tab.id, for: target)
            }
            // Measure in .global space: a .local drag reads coordinates relative to the
            // chip, which itself moves via .offset(dragTranslation) — that feedback loop
            // dampens the translation so the chip lags the cursor. Global space is fixed.
            .gesture(
              DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { value in
                  if draggingID == nil { draggingID = tab.id }
                  guard draggingID == tab.id else { return }
                  dragTranslation = value.translation.width
                  // Dragged down over the pane area → preview a drop-into-pane (the strip stops gapping).
                  chipPaneDrag = localize(value.location)
                    .map { PaneDragState(tabID: tab.id, location: $0) }
                }
                .onEnded { value in
                  if let drop = dropTarget(value.location) {
                    sessions.moveTabIntoSplit(
                      tab.id, ontoEdge: drop.edge, of: drop.tab, for: target)
                    draggingID = nil
                    dragTranslation = 0
                  } else {
                    commitDrag()  // a plain strip reorder
                  }
                  chipPaneDrag = nil
                }
            )
            .offset(x: offsetX)
            .zIndex(isDragging ? 1 : 0)
            .animation(
              isDragging || reduceMotion ? nil : .easeInOut(duration: 0.18), value: offsetX)
          }
        }
        .background(alignment: .leading) { splitWell(tabs) }
        .padding(.horizontal, 8)
        .onPreferenceChange(TabWidthKey.self) { widths = $0 }
      }
      // Hug the chips' height; otherwise the horizontal ScrollView grabs all the vertical slack
      // when there's no terminal below it (the empty state), ballooning the tab bar.
      .fixedSize(horizontal: false, vertical: true)
      Button {
        sessions.addTab(for: target)
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .padding(4)
          .background(
            RoundedRectangle(cornerRadius: 5)
              .fill(Color.primary.opacity(addHovering ? 0.1 : 0))
          )
      }
      .buttonStyle(.plain)
      .onHover { addHovering = $0 }
      .padding(.horizontal, 8)
      .help("New terminal")
      .accessibilityLabel("New terminal")
      .accessibilityIdentifier("NewTerminal")
    }
    .padding(.vertical, 4)
  }

  /// A rounded *outline* + accent underline bracketing the split's contiguous chip run, so it's easy
  /// to see which tabs are grouped/split (issue #3). Deliberately an outline, not a filled backing: a
  /// fill occupies the same channel as the active-chip fill, so any visible strength made a
  /// grouped-but-inactive chip read as focused. The border groups without competing with selection.
  /// Hidden during a drag (group-aware strip drag is Phase 2), and only shown for a real split (≥2).
  @ViewBuilder
  private func splitWell(_ tabs: [TerminalTab]) -> some View {
    if draggingID == nil, let run = splitRunRect(tabs) {
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        .overlay(alignment: .bottom) {
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor.opacity(0.55))
            .frame(height: 2)
            .padding(.horizontal, 3)
        }
        .frame(width: run.width)
        .offset(x: run.x)
    }
  }

  /// The x-offset and width of the split members' contiguous run within the chip strip, in the chips'
  /// coordinate space (x = 0 at the first chip). `nil` when there's no split. Members are guaranteed
  /// contiguous by `displayedTabIDs`.
  private func splitRunRect(_ tabs: [TerminalTab]) -> (x: CGFloat, width: CGFloat)? {
    guard let members = sessions.split(for: target)?.tabIDs, members.count >= 2 else { return nil }
    let memberSet = Set(members)
    let idxs = tabs.indices.filter { memberSet.contains(tabs[$0].id) }
    guard let first = idxs.first, let last = idxs.last else { return nil }
    var x: CGFloat = 0
    for i in 0..<first { x += (widths[tabs[i].id] ?? 0) + tabSpacing }
    var width: CGFloat = 0
    for i in first...last { width += widths[tabs[i].id] ?? 0 }
    width += tabSpacing * CGFloat(last - first)
    return (x, width)
  }

  /// Where the dragged tab would land given its current translation: walk outward from
  /// its start index, crossing each neighbour once the drag passes that neighbour's
  /// half-width. Reaches index 0 and the last slot.
  private func dropTargetIndex(_ tabs: [TerminalTab], draggedIndex di: Int) -> Int {
    var idx = di
    if dragTranslation > 0 {
      var accumulated: CGFloat = 0
      var j = di + 1
      while j < tabs.count {
        let span = (widths[tabs[j].id] ?? 0) + tabSpacing
        if dragTranslation > accumulated + span / 2 {
          idx = j
          accumulated += span
          j += 1
        } else {
          break
        }
      }
    } else if dragTranslation < 0 {
      var accumulated: CGFloat = 0
      var j = di - 1
      while j >= 0 {
        let span = (widths[tabs[j].id] ?? 0) + tabSpacing
        if -dragTranslation > accumulated + span / 2 {
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

  /// Horizontal shift for a non-dragged chip so the row opens a gap at the drop target.
  private func gapShift(for index: Int, draggedIndex: Int?, target: Int?, amount: CGFloat)
    -> CGFloat
  {
    guard let di = draggedIndex, let ti = target else { return 0 }
    if di < ti, index > di, index <= ti { return -amount }  // dragging right: slide left
    if di > ti, index >= ti, index < di { return amount }  // dragging left: slide right
    return 0
  }

  /// Commit the reorder on drop, then clear drag state (animated, so everything settles).
  private func commitDrag() {
    let tabs = sessions.tabs(for: target)
    if let id = draggingID, let di = tabs.firstIndex(where: { $0.id == id }) {
      let ti = dropTargetIndex(tabs, draggedIndex: di)
      withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
        sessions.moveTab(id, toIndex: ti, for: target)
        draggingID = nil
        dragTranslation = 0
      }
    } else {
      draggingID = nil
      dragTranslation = 0
    }
  }
}

/// A single terminal tab chip: its title, an always-visible close button, and the active/hover/
/// activity/dragging styling. Purely presentational — the strip wraps it with the hover, tap, and
/// drag gestures, since those drive (and read) the strip's shared drag state.
private struct TerminalTabChip: View {
  let tab: TerminalTab
  let isActive: Bool
  let isHovered: Bool
  let isDragging: Bool
  let hasActivity: Bool
  let onClose: () -> Void

  var body: some View {
    // Title and close button laid out side by side: a compact gap keeps the ✕ visibly tied to its
    // tab (a wide gap reads as detached) while still clearing the title so they never crowd.
    HStack(spacing: 6) {
      Text(tab.title)
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(hasActivity ? Color.accentColor : Color.primary)
      TabCloseButton(action: onClose)
        .help("Close \(tab.title)")
        .accessibilityLabel("Close \(tab.title)")
    }
    .padding(.leading, 10)
    .padding(.trailing, 4)  // tighter than the leading inset — the ✕ sits near the chip's edge
    .padding(.vertical, 4)
    // Subtle highlight for active/hover; a solid lifted chip while dragging.
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.primary.opacity(isActive ? 0.14 : (isHovered ? 0.06 : 0)))
    }
    // Unread activity tints the whole tab with the accent color (pairs with the accent title).
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.accentColor.opacity(hasActivity ? 0.15 : 0))
    }
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(.thickMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .opacity(isDragging ? 1 : 0)
    }
    // Measure the chip's natural width for the drag gap math.
    .background {
      GeometryReader { geo in
        Color.clear.preference(key: TabWidthKey.self, value: [tab.id: geo.size.width])
      }
    }
    // A flowing underline along the chip's base while a command runs in this tab (issue #28).
    // An overlay so it never changes the chip's measured width (the drag gap math reads that).
    .overlay(alignment: .bottom) {
      if tab.isRunning {
        RunningUnderline()
          .padding(.horizontal, 6)
          .padding(.bottom, 1)
      }
    }
    .contentShape(Rectangle())
    .accessibilityIdentifier("terminal.tab.\(tab.title)")
    .scaleEffect(isDragging ? 1.04 : 1)
    .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 6 : 0, y: 2)
  }
}

/// Collects each tab chip's natural width for the drag gap math.
private struct TabWidthKey: PreferenceKey {
  static var defaultValue: [TerminalTab.ID: CGFloat] = [:]
  static func reduce(
    value: inout [TerminalTab.ID: CGFloat], nextValue: () -> [TerminalTab.ID: CGFloat]
  ) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// A thin accent underline that flows left→right while a command runs in a tab (issue #28): a base
/// accent track with a brighter highlight that sweeps across it, conveying indeterminate progress.
/// Under Reduce Motion the sweep is dropped for a static, fuller-opacity track.
private struct RunningUnderline: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var sweeping = false

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let highlight = max(20, width * 0.4)
      Capsule()
        .fill(Color.accentColor.opacity(reduceMotion ? 0.7 : 0.25))
        .overlay(alignment: .leading) {
          if !reduceMotion {
            Capsule()
              .fill(
                LinearGradient(
                  colors: [.clear, Color.accentColor, .clear],
                  startPoint: .leading, endPoint: .trailing)
              )
              .frame(width: highlight)
              // Travel the highlight from just off the leading edge to just off the trailing edge.
              .offset(x: sweeping ? width : -highlight)
          }
        }
        .clipShape(Capsule())
    }
    .frame(height: 2)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
        sweeping = true
      }
    }
  }
}

/// A tab's close button, overlaid on the title's right edge. Its own hover paints a subtle
/// background behind the ✕. (Show/hide is handled by the caller's overlay.)
private struct TabCloseButton: View {
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(hovering ? .primary : .secondary)
        .padding(3)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.primary.opacity(hovering ? 0.15 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}
