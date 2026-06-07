import SwiftUI

/// The detail pane's terminals for one target (a workroom or a project root): a horizontal
/// tab strip below the title bar plus the active terminal. Observes `TerminalSessions` so
/// adding, closing, and switching tabs all update live.
struct WorkroomTerminalsView: View {
  let target: TerminalTarget
  @ObservedObject var sessions: TerminalSessions
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var hoveredTab: TerminalTab.ID?
  @State private var addHovering = false

  // Drag-to-reorder. The tab order is *frozen* for the duration of a drag: the dragged
  // chip simply follows the cursor (its slot never moves, so it can't jump), and the
  // other chips slide aside to open a gap. The reorder is committed once, on drop.
  @State private var draggingID: TerminalTab.ID?
  @State private var dragTranslation: CGFloat = 0
  @State private var widths: [TerminalTab.ID: CGFloat] = [:]

  // Drag a tab chip down into a pane to split (issue #3). `chipPaneDrag` is the live drop preview
  // (content-local), shown by `PaneTreeView`; `contentFrame` is the pane area's global rect, used to
  // tell "over the strip" (reorder) from "over a pane" (drop-to-split) and to localise the cursor.
  @State private var chipPaneDrag: PaneDragState?
  @State private var contentFrame: CGRect = .zero

  private let tabSpacing: CGFloat = 4

  var body: some View {
    let tabs = sessions.tabs(for: target)
    let active = sessions.activeTab(for: target)
    // The terminal (or empty state) fills the pane; the tab bar rides on safeAreaInset so it only
    // ever takes its natural height — otherwise the tab bar's horizontal ScrollView grabs the
    // vertical slack when there's no terminal below it and balloons.
    Group {
      if let active {
        // Always render through the one pane tree — a solo terminal is just a single-leaf layout.
        // Routing solo and split through the SAME host means a surface has exactly one owner; an
        // earlier split→solo bug came from two `TerminalContainerView`s (the solo branch and the dying
        // split leaf) fighting over the same surface and stranding it in a detached container (#3).
        PaneTreeView(
          layout: contentLayout(active: active), target: target, sessions: sessions,
          externalDrag: chipPaneDrag
        )
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: ContentFrameKey.self, value: geo.frame(in: .global))
          }
        )
        .padding(8)
      } else {
        ContentUnavailableView {
          Label("No terminal", systemImage: "terminal")
        } description: {
          Text("Open one with ⌘T.")
        } actions: {
          Button("New Terminal") { sessions.addTab(for: target) }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("NewTerminal")
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onPreferenceChange(ContentFrameKey.self) { contentFrame = $0 }
    .safeAreaInset(edge: .top, spacing: 0) {
      // No tab bar when there are no terminals: the empty state's "New Terminal" button (and ⌘T)
      // cover adding one, so the strip and its "+" would be redundant.
      if !tabs.isEmpty {
        VStack(spacing: 0) {
          tabBar(tabs, activeID: active?.id)
          Divider()
        }
      }
    }
    // Create the first terminal once the pane appears (and for each new target), then reconcile
    // occlusion so the right surfaces render after a target switch (issue #3).
    .task(id: target.id) {
      sessions.ensureTab(for: target)
      sessions.reconcileOcclusion(for: target)
    }
    // Focusing a terminal dismisses its notifications. This view only ever renders the selected
    // target's active terminal, so `active.id` changing *is* a focus change — whether from a chip
    // tap, ⌘1–9, the sidebar switching targets, or a close revealing a neighbour. One hook covers
    // them all; `initial` handles the target's first appearance (e.g. arriving from the empty state
    // with notifications already waiting). Returning to the app with the same tab still focused is
    // handled separately by RootView's didBecomeActive → dismissFocusedTerminalNotifications.
    .onChange(of: active?.id, initial: true) { _, id in
      if let id { notifications.dismiss(tab: id) }
    }
    // Drive the "Close Terminal" menu command's enabled state.
    .focusedSceneValue(\.hasTerminal, !tabs.isEmpty)
  }

  /// The layout the content area renders: the split when it's visible, else the focused solo tab.
  private func contentLayout(active: TerminalTab) -> PaneLayout {
    sessions.isSplitVisible(for: target)
      ? (sessions.split(for: target) ?? .leaf(active.id)) : .leaf(active.id)
  }

  /// The content-local point for a chip drag at `global`, or nil when the cursor is outside the pane
  /// area (i.e. still over the strip → a reorder, not a drop-into-pane).
  private func chipLocal(_ global: CGPoint) -> CGPoint? {
    guard contentFrame.contains(global) else { return nil }
    return CGPoint(x: global.x - contentFrame.minX, y: global.y - contentFrame.minY)
  }

  /// Where a chip dropped at `global` lands (pane + edge), using the same pane plan the renderer uses,
  /// or nil if it isn't over a pane.
  private func chipDropTarget(at global: CGPoint) -> (tab: TerminalTab.ID, edge: PaneEdge)? {
    guard let local = chipLocal(global), let active = sessions.activeTab(for: target) else {
      return nil
    }
    let plan = PaneTreeLayout.plan(
      contentLayout(active: active), in: CGRect(origin: .zero, size: contentFrame.size))
    return PaneTreeLayout.dropTarget(at: local, panes: plan.panes)
  }

  /// A rounded "well" + accent underline behind the split's contiguous chip run, so it's easy to see
  /// which tabs are grouped/split (issue #3). Hidden during a drag (group-aware strip drag is Phase 2),
  /// and only shown for a real split (≥2 members).
  @ViewBuilder
  private func splitWell(_ tabs: [TerminalTab]) -> some View {
    if draggingID == nil, let run = splitRunRect(tabs) {
      RoundedRectangle(cornerRadius: 7)
        .fill(Color.primary.opacity(0.06))
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

  private func tabBar(_ tabs: [TerminalTab], activeID: TerminalTab.ID?) -> some View {
    // Resolve the drag once per layout: which tab is dragging, and where it would land.
    let draggedIndex = draggingID.flatMap { id in tabs.firstIndex { $0.id == id } }
    // While dragging a chip down into a pane, the strip stops opening a reorder gap.
    let dropTarget = chipPaneDrag != nil ? nil : draggedIndex.map { dropTargetIndex(tabs, draggedIndex: $0) }
    let draggedWidth = draggingID.flatMap { widths[$0] } ?? 0

    return HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: tabSpacing) {
          ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
            let isDragging = draggingID == tab.id
            // Dragged chip tracks the cursor; the rest shift to open the gap.
            let offsetX =
              isDragging
              ? dragTranslation
              : gapShift(
                for: index, draggedIndex: draggedIndex, target: dropTarget,
                amount: draggedWidth + tabSpacing)
            tabChip(tab, isActive: tab.id == activeID, isDragging: isDragging)
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

  private func tabChip(_ tab: TerminalTab, isActive: Bool, isDragging: Bool) -> some View {
    let isHovered = hoveredTab == tab.id && draggingID == nil
    // Activity in an unfocused tab highlights the tab itself (accent title + faint accent
    // fill) instead of a count — a tab is too narrow for a number.
    let hasActivity = notifications.count(tab: tab.id) > 0
    // Title and close button laid out side by side: the ✕ is always visible (no hover gate) and
    // set well clear of the title by the HStack spacing, so they never crowd or overlap.
    return HStack(spacing: 12) {
      Text(tab.title)
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(hasActivity ? Color.accentColor : Color.primary)
      TabCloseButton {
        store.requestCloseTerminalTab(tab.id, for: target)
      }
      .help("Close \(tab.title)")
      .accessibilityLabel("Close \(tab.title)")
    }
    .padding(.leading, 10)
    .padding(.trailing, 4)  // tighter than the leading inset — the ✕ sits near the chip's edge
    .padding(.vertical, 4)
    // Subtle highlight for active/hover; a solid lifted chip while dragging.
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(Color.primary.opacity(isActive ? 0.1 : (isHovered ? 0.05 : 0)))
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
          chipPaneDrag = chipLocal(value.location).map { PaneDragState(tabID: tab.id, location: $0) }
        }
        .onEnded { value in
          if let drop = chipDropTarget(at: value.location) {
            sessions.moveTabIntoSplit(tab.id, ontoEdge: drop.edge, of: drop.tab, for: target)
            draggingID = nil
            dragTranslation = 0
          } else {
            commitDrag()  // a plain strip reorder
          }
          chipPaneDrag = nil
        }
    )
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

/// Collects each tab chip's natural width for the drag gap math.
private struct TabWidthKey: PreferenceKey {
  static var defaultValue: [TerminalTab.ID: CGFloat] = [:]
  static func reduce(
    value: inout [TerminalTab.ID: CGFloat], nextValue: () -> [TerminalTab.ID: CGFloat]
  ) {
    value.merge(nextValue()) { _, new in new }
  }
}

/// The pane area's global frame — lets the strip localise a chip drag and tell "over the strip"
/// (reorder) from "over a pane" (drop-to-split).
private struct ContentFrameKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero { value = next }
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
