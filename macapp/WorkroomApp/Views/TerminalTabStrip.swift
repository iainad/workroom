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
  /// When this target is a member of a *workroom* split (issue #23 follow-up), the action that removes
  /// it from the split. Rendered as a trailing control pinned to the strip's right edge — a layout
  /// sibling of the scrolling tabs, so it never overlaps them no matter how many tabs there are. nil
  /// (the default) outside a split: no control.
  var onCloseWorkroomPane: (() -> Void)? = nil

  @State private var hoveredTab: TerminalTab.ID?
  @State private var addHovering = false
  /// The last chip click (id + time), so a quick second click on the same chip promotes a preview
  /// content tab to persisted without delaying the eager first-click select (#66).
  @State private var lastChipClick: ChipClick?

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
            // Run-command state for this tab's chip icon (issue #7): only the dedicated run tab
            // carries one — running (green) vs stopped/exited (dim). Process-based, distinct from the
            // OSC-9;4 RunningUnderline below.
            let runState: TerminalTabChip.RunState? =
              store.runTabID(for: target.id) == tab.id
              ? (store.isRunCommandRunning(for: target.id) ? .running : .stopped) : nil
            // Dragged chip tracks the cursor; the rest shift to open the gap.
            let offsetX =
              isDragging
              ? dragTranslation
              : gapShift(
                for: index, draggedIndex: draggedIndex, target: dropIndex,
                amount: draggedWidth + tabSpacing)
            TerminalTabChip(
              tab: tab, isActive: tab.id == activeID, isHovered: isHovered,
              isDragging: isDragging, hasActivity: hasActivity, runState: runState,
              showLeadingSeparator: showsLeadingSeparator(at: index)
            ) {
              store.requestCloseTerminalTab(tab.id, for: target)
            }
            .onHover { inside in
              if inside { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil }
            }
            .onTapGesture {
              // Eager: select on the first click (changes `active.id`; the view's .onChange hook
              // marks the tab read). A quick second click on the same chip promotes a preview content
              // tab to persisted (#66) — `persist` no-ops on terminal/persisted tabs, so this is safe
              // for every chip and never delays the select.
              let now = Date()
              sessions.select(tab.id, for: target)
              if let last = lastChipClick, last.id == tab.id, now.timeIntervalSince(last.at) < 0.35
              {
                sessions.persist(tab.id, for: target)
                lastChipClick = nil
              } else {
                lastChipClick = ChipClick(id: tab.id, at: now)
              }
            }
            .tabChipContextMenu(tab: tab, target: target, store: store)
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
          addTerminalButton
        }
        .background(alignment: .leading) { splitWell(tabs) }
        .padding(.horizontal, 8)
        .onPreferenceChange(TabWidthKey.self) { widths = $0 }
      }
      // Hug the chips' height; otherwise the horizontal ScrollView grabs all the vertical slack
      // when there's no terminal below it (the empty state), ballooning the tab bar.
      .fixedSize(horizontal: false, vertical: true)
      // Remove-from-split control (issue #23 follow-up), pinned to the strip's right edge as a layout
      // sibling of the scrolling tabs — so it never overlaps them however many tabs there are. Only a
      // workroom split member gets one (the callback is nil otherwise).
      if let onCloseWorkroomPane {
        CloseWorkroomPaneButton(action: onCloseWorkroomPane)
      }
    }
    .padding(.top, 4)
    .padding(.bottom, 2)
  }

  /// The "new terminal" (+) button. Lives inside the scrolling tab row, immediately after the last tab
  /// (it scrolls with the tabs), rather than pinned to the far right of the strip — so it sits next to
  /// the rightmost tab and never collides with the trailing remove-from-split control.
  private var addTerminalButton: some View {
    Button {
      sessions.addTab(for: target)
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(ThemeService.shared.tokens.hover.opacity(addHovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { addHovering = $0 }
    .padding(.leading, 2)
    .help("New terminal")
    .accessibilityLabel("New terminal")
    .accessibilityIdentifier("NewTerminal")
  }

  /// A rounded *outline* bracketing the split's contiguous chip run, so it's easy to see which tabs
  /// are grouped/split (issue #3). Deliberately an outline, not a filled backing: a fill occupies the
  /// same channel as the active-chip fill, so any visible strength made a grouped-but-inactive chip
  /// read as focused. The border groups without competing with selection. Hidden during a drag
  /// (group-aware strip drag is Phase 2), and only shown for a real split (≥2).
  @ViewBuilder
  private func splitWell(_ tabs: [TerminalTab]) -> some View {
    if draggingID == nil, let run = splitRunRect(tabs) {
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(ThemeService.shared.tokens.border, lineWidth: 1)
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

  /// Where the dragged tab would land given its current translation (delegates to the shared
  /// `TabReorder` math, mapping this strip's tabs to position-indexed widths).
  private func dropTargetIndex(_ tabs: [TerminalTab], draggedIndex di: Int) -> Int {
    TabReorder.dropTargetIndex(
      widths: tabs.map { widths[$0.id] ?? 0 }, draggedIndex: di,
      translation: dragTranslation, spacing: tabSpacing)
  }

  /// Horizontal shift for a non-dragged chip so the row opens a gap at the drop target (delegates to
  /// the shared `TabReorder` math).
  private func gapShift(for index: Int, draggedIndex: Int?, target: Int?, amount: CGFloat)
    -> CGFloat
  {
    TabReorder.gapShift(index: index, draggedIndex: draggedIndex, target: target, amount: amount)
  }

  /// Whether to draw a hairline on the leading edge of tab `index`, separating it from its left
  /// neighbour. Shown only between two adjacent tabs that are **both** idle — not active, not hovered —
  /// and never during a drag (reorder or drop-into-pane), so the divider quietly vanishes around the
  /// tab you're pointing at or have focused. Drawn between split-grouped members too (inside the
  /// `splitWell` bracket), but dropped at the group's **outer** boundary (exactly one neighbour is a
  /// member) where the bracket already separates it — a hairline there doubles up against its rounded
  /// border. Mirrors `WorkroomTabBar`.
  private func showsLeadingSeparator(at index: Int) -> Bool {
    guard index > 0, draggingID == nil, chipPaneDrag == nil else { return false }
    let here = tabs[index].id
    let prev = tabs[index - 1].id
    if here == activeID || prev == activeID { return false }
    if hoveredTab == here || hoveredTab == prev { return false }
    let members = splitMemberSet
    if members.contains(here) != members.contains(prev) { return false }
    return true
  }

  /// The split group's members (≥2), or empty when there's no split — used to drop the separator at
  /// the group's outer edges (see `showsLeadingSeparator`).
  private var splitMemberSet: Set<TerminalTab.ID> {
    guard let members = sessions.split(for: target)?.tabIDs, members.count >= 2 else { return [] }
    return Set(members)
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
  /// The run-command state shown as a leading chip icon — only the dedicated run tab has one (#7).
  enum RunState { case running, stopped }

  let tab: TerminalTab
  let isActive: Bool
  let isHovered: Bool
  let isDragging: Bool
  let hasActivity: Bool
  let runState: RunState?
  /// Draw a hairline on the leading edge, separating two adjacent idle tabs (computed by the strip).
  let showLeadingSeparator: Bool
  let onClose: () -> Void
  private let theme = ThemeService.shared

  var body: some View {
    // The ✕ reveals on hover or when the tab is active — matching the sidebar's terminal rows, and
    // sparing the strip a close glyph on every idle tab. It stays *laid out* (opacity, not removed)
    // so the chip's measured width — which the drag-gap math reads — is stable whether or not it shows.
    let showClose = isActive || isHovered
    // Title and close button laid out side by side: a compact gap keeps the ✕ visibly tied to its
    // tab (a wide gap reads as detached) while still clearing the title so they never crowd.
    HStack(spacing: 6) {
      // Leading state dot for the run tab (#7): green while the command runs, dim once it has exited.
      // Same glyph as the sidebar run dot, so the two read as one signal.
      if let runState {
        Image(systemName: "play.circle.fill")
          .font(.system(size: 10))
          .foregroundStyle(runState == .running ? Color.green : theme.tokens.fgMuted)
          .help(runState == .running ? "Run command running" : "Run command stopped")
          .accessibilityLabel(runState == .running ? "running" : "stopped")
      }
      // A diff (content) tab gets a leading glyph so it reads as not-a-terminal at a glance (#66).
      if case .diff = tab.content {
        Image(systemName: "plusminus")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(theme.tokens.fgMuted)
          .accessibilityHidden(true)
      }
      // Unread activity is marked by a leading accent dot (+ accent title) — a different visual
      // primitive from the selected tab's neutral fill, so the two never read alike.
      if hasActivity {
        Circle()
          .fill(theme.tokens.accent)
          .frame(width: 6, height: 6)
          .accessibilityHidden(true)
      }
      Text(tab.title)
        .font(.callout)
        // A preview tab's name is italic until it's persisted (VS-Code semantics, #66).
        .italic(tab.isPreview)
        .lineLimit(1)
        .foregroundStyle(hasActivity ? theme.tokens.accent : Color.primary)
      TabCloseButton(action: onClose)
        .help("Close \(tab.title)")
        .accessibilityLabel("Close \(tab.title)")
        .opacity(showClose ? 1 : 0)
        .allowsHitTesting(showClose)
    }
    .padding(.leading, 10)
    .padding(.trailing, 4)  // tighter than the leading inset — the ✕ sits near the chip's edge
    .padding(.vertical, 4)
    // The active tab gets a distinctly stronger fill (tabActive) than the faint hover wash, so the
    // selected tab reads at a glance; a solid lifted chip while dragging.
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(isActive ? theme.tokens.tabActive : (isHovered ? theme.tokens.hover : Color.clear))
    }
    .background {
      RoundedRectangle(cornerRadius: 6)
        .fill(.thickMaterial)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(theme.tokens.border, lineWidth: 1)
        )
        .opacity(isDragging ? 1 : 0)
    }
    // Measure the chip's natural width for the drag gap math.
    .background {
      GeometryReader { geo in
        Color.clear.preference(key: TabWidthKey.self, value: [tab.id: geo.size.width])
      }
    }
    // Hairline between two idle neighbours, centred in the *visible* whitespace between the two
    // titles. An overlay (not an HStack element) so it never enters the width the drag math measures.
    // Unlike WorkroomTabBar's symmetric chips, a terminal chip always reserves its trailing close
    // button even when hidden, so the title sits well left of the chip's right edge — centring on the
    // geometric chip gap would jam the line against the right tab. The midpoint of [previous title's
    // trailing edge … this title's leading edge] is ≈ (−(tabSpacing 4 + spacing 6 + closeButton ~15 +
    // trailing 4) + leading 10) / 2 = −9.5; the leading-anchored 1pt rect centres at +0.5, so offset
    // another −0.5 → −10 to sit on that midpoint.
    .overlay(alignment: .leading) {
      if showLeadingSeparator {
        Rectangle()
          .fill(theme.tokens.border)
          .frame(width: 1, height: 14)
          .offset(x: -10)
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
/// Reused by `WorkroomTabBar`'s chips so a busy workroom tab shows the same flowing underline.
struct RunningUnderline: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var sweeping = false
  private let theme = ThemeService.shared

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let highlight = max(20, width * 0.4)
      Capsule()
        .fill(theme.tokens.accent.opacity(reduceMotion ? 0.7 : 0.25))
        .overlay(alignment: .leading) {
          if !reduceMotion {
            Capsule()
              .fill(
                LinearGradient(
                  colors: [.clear, theme.tokens.accent, .clear],
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
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(hovering ? .primary : .secondary)
        .padding(3)
        .background(
          RoundedRectangle(cornerRadius: 4)
            .fill(theme.tokens.hover.opacity(hovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
  }
}

/// The remove-from-split (✕) control for a workroom split member (issue #23 follow-up). Pinned at the
/// tab strip's right edge in the normal case, and also surfaced as a corner overlay by
/// `TargetTerminalDetail` while a setup script blocks the strip (so a mid-setup member can still leave
/// the split). A view (not an inline button) so it carries its own `onHover` — which both gives the
/// subtle hover feedback the other strip controls have AND ensures the `.help` tooltip's tracking area
/// is installed (a bare `.help` without any hover tracking can silently fail to show).
struct CloseWorkroomPaneButton: View {
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 12))
        .foregroundStyle(hovering ? .primary : .secondary)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    .help("Remove this workroom from the split")
    .accessibilityLabel("Remove workroom from split")
    .accessibilityIdentifier("workroom.pane.close")
  }
}

/// The last chip click — id + time — used by the strip's eager single/double tap discrimination (#66).
private struct ChipClick {
  let id: TerminalTab.ID
  let at: Date
}

extension View {
  /// Attach a context menu to a **diff (content)** chip only (#66): "Keep Open" promotes a preview
  /// tab to persisted; "Close" closes it. Terminal chips are returned unchanged (no menu), so this
  /// adds nothing to their right-click behaviour.
  @ViewBuilder
  fileprivate func tabChipContextMenu(
    tab: TerminalTab, target: TerminalTarget, store: AppStore
  ) -> some View {
    self.contextMenu {
      Button(role: .destructive) {
        store.requestCloseTerminalTab(tab.id, for: target)
      } label: {
        Label("Close", systemImage: "xmark")
      }
    }
  }
}
