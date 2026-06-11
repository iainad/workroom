import SwiftUI

/// The workroom tab bar shown above the terminal (issue #23): a chip per active target (a workroom or
/// project root with ≥1 terminal), drag-to-reorder (reusing the shared `TabReorder` math). A tab
/// appears when its workroom gains a terminal and disappears when it loses its last. The "selected"
/// chip **is** `store.selectedTargetID` — tapping one selects that target (like the sidebar), so every
/// selection-driven command (⌘T/⌘W/splits/run/notifications/⌥⌘1–9) operates on the focused workroom.
/// No per-chip close button: a tab vanishes when its terminals are closed, and closing-as-kill would
/// defeat the parallel-monitoring purpose.
struct WorkroomTabBar: View {
  let tabs: [(sid: SidebarID, target: TerminalTarget)]
  let selectedID: SidebarID?
  let onSelect: (SidebarID) -> Void

  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @State private var hoveredID: SidebarID?

  // Drag-to-reorder: the order is frozen during a drag (the dragged chip follows the cursor, the rest
  // slide aside to open a gap), committed once on drop — mirrors `TerminalTabStrip`.
  @State private var draggingID: SidebarID?
  @State private var dragTranslation: CGFloat = 0
  @State private var widths: [SidebarID: CGFloat] = [:]

  private let tabSpacing: CGFloat = 4

  var body: some View {
    let draggedIndex = draggingID.flatMap { id in tabs.firstIndex { $0.sid == id } }
    let dropIndex = draggedIndex.map {
      TabReorder.dropTargetIndex(
        widths: tabs.map { widths[$0.sid] ?? 0 }, draggedIndex: $0,
        translation: dragTranslation, spacing: tabSpacing)
    }
    let draggedWidth = draggingID.flatMap { widths[$0] } ?? 0

    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: tabSpacing) {
        ForEach(Array(tabs.enumerated()), id: \.element.sid) { index, tab in
          let isDragging = draggingID == tab.sid
          let isHovered = hoveredID == tab.sid && draggingID == nil
          let offsetX =
            isDragging
            ? dragTranslation
            : TabReorder.gapShift(
              index: index, draggedIndex: draggedIndex, target: dropIndex,
              amount: draggedWidth + tabSpacing)
          WorkroomTabChip(
            sid: tab.sid, target: tab.target, isActive: tab.sid == selectedID,
            isHovered: isHovered, isDragging: isDragging,
            showLeadingSeparator: showsLeadingSeparator(at: index)
          )
          .onHover { inside in
            if inside { hoveredID = tab.sid } else if hoveredID == tab.sid { hoveredID = nil }
          }
          .onTapGesture { onSelect(tab.sid) }
          // Measure in .global space (a .local drag reads coordinates relative to the chip, which
          // itself moves via .offset — that feedback loop lags the cursor). Mirrors TerminalTabStrip.
          .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
              .onChanged { value in
                if draggingID == nil { draggingID = tab.sid }
                guard draggingID == tab.sid else { return }
                dragTranslation = value.translation.width
              }
              .onEnded { _ in commitDrag() }
          )
          .offset(x: offsetX)
          .zIndex(isDragging ? 1 : 0)
          .animation(
            isDragging || reduceMotion ? nil : .easeInOut(duration: 0.18), value: offsetX)
        }
      }
      .padding(.horizontal, 8)
      .onPreferenceChange(WorkroomTabWidthKey.self) { widths = $0 }
    }
    // Hug the chips' height so the horizontal ScrollView doesn't grab vertical slack.
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 6)
  }

  /// Whether to draw a hairline on the leading edge of tab `index`, separating it from its left
  /// neighbour. Shown only between two adjacent tabs that are **both** idle — not selected, not
  /// hovered — and never mid-drag, so the divider quietly vanishes around the tab you're pointing at or
  /// have focused (the highlight already sets those apart). Like a segmented control dropping the
  /// divider next to its active segment.
  private func showsLeadingSeparator(at index: Int) -> Bool {
    guard index > 0, draggingID == nil else { return false }
    let here = tabs[index].sid
    let prev = tabs[index - 1].sid
    if here == selectedID || prev == selectedID { return false }
    if hoveredID == here || hoveredID == prev { return false }
    return true
  }

  /// Commit the reorder on drop: rewrite `store.workroomTabOrder` (a `@Published`, so the parent view
  /// re-renders with the new order — a bare `Defaults` write didn't re-render, so the chip snapped
  /// back), then clear drag state (animated, so the row settles). The order is filtered through
  /// `orderedActiveTargets` on every read, so writing the current active order is self-healing.
  private func commitDrag() {
    guard let id = draggingID, let di = tabs.firstIndex(where: { $0.sid == id }) else {
      draggingID = nil
      dragTranslation = 0
      return
    }
    let ti = TabReorder.dropTargetIndex(
      widths: tabs.map { widths[$0.sid] ?? 0 }, draggedIndex: di,
      translation: dragTranslation, spacing: tabSpacing)
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
      if ti != di {
        var order = tabs.compactMap { AppStore.targetIDString(for: $0.sid) }
        let moved = order.remove(at: di)
        order.insert(moved, at: ti)
        store.workroomTabOrder = order
      }
      draggingID = nil
      dragTranslation = 0
    }
  }
}

/// A single Workrooms View tab chip: a project-qualified label with run / unread / active styling.
/// Workroom chips read "project / name"; root chips show the project name, then a house glyph, then
/// the branch/ref (reusing `RootPresentation`) — the house sits between the name and the branch so it
/// reads as "this project's root, on <branch>". The full path is the tooltip, so two same-named
/// workrooms across projects stay distinct. Reads the store for unread + run-command state; the bar
/// wraps it with the gestures.
private struct WorkroomTabChip: View {
  let sid: SidebarID
  let target: TerminalTarget
  let isActive: Bool
  let isHovered: Bool
  let isDragging: Bool
  /// Draw a hairline on the leading edge, separating two adjacent idle tabs (computed by the bar).
  let showLeadingSeparator: Bool

  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore

  private var isRoot: Bool {
    if case .root = sid { return true }
    return false
  }

  /// "project / workroom" for a workroom; the project name alone for a root (its branch rides as a
  /// secondary label after the house glyph).
  private var primaryLabel: String {
    switch sid {
    case .workroom(let project, let name):
      return "\((project as NSString).lastPathComponent) / \(name)"
    case .root(let project), .project(let project):
      return (project as NSString).lastPathComponent
    }
  }

  /// A root's branch/bookmark (nil for a workroom), reusing the sidebar's root presentation.
  private var branchLabel: String? {
    guard case .root(let project) = sid else { return nil }
    return RootPresentation.make(store.rootRefs[project] ?? .unresolved).label
  }

  var body: some View {
    let hasActivity = notifications.count(target: target.id) > 0
    let hasRunTab = store.runTabID(for: target.id) != nil
    let runRunning = store.isRunCommandRunning(for: target.id)
    HStack(spacing: 6) {
      // Run-command dot (issue #7), same glyph as the terminal strip + sidebar: green while running,
      // dim once it has exited. Only shown when this target has a dedicated run terminal.
      if hasRunTab {
        Image(systemName: "play.circle.fill")
          .font(.system(size: 10))
          .foregroundStyle(runRunning ? Color.green : Color.secondary)
          .help(runRunning ? "Run command running" : "Run command stopped")
      }
      if target.isMissing {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10))
          .foregroundStyle(.orange)
          .help("Directory not found")
      }
      Text(primaryLabel)
        .font(.callout)
        .lineLimit(1)
        .foregroundStyle(hasActivity ? Color.accentColor : Color.primary)
      // House glyph for a root, between the project name and its branch (so the two read together).
      if isRoot {
        Image(systemName: "house")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
      if let branchLabel {
        Text(branchLabel)
          .font(.caption)
          .lineLimit(1)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
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
        Color.clear.preference(key: WorkroomTabWidthKey.self, value: [sid: geo.size.width])
      }
    }
    // Hairline between two idle neighbours, centred in the 4pt inter-chip gap. An overlay (not an
    // extra HStack element) so it never enters the width the drag math measures.
    .overlay(alignment: .leading) {
      if showLeadingSeparator {
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(width: 1, height: 16)
          .offset(x: -2)
      }
    }
    .contentShape(Rectangle())
    .help(target.path)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      accessibilityLabel(hasActivity: hasActivity, running: hasRunTab && runRunning)
    )
    .accessibilityIdentifier("workroom.tab.\(target.id)")
    .scaleEffect(isDragging ? 1.04 : 1)
    .shadow(color: .black.opacity(isDragging ? 0.25 : 0), radius: isDragging ? 6 : 0, y: 2)
  }

  private func accessibilityLabel(hasActivity: Bool, running: Bool) -> String {
    var parts = [primaryLabel]
    if let branchLabel { parts.append("on \(branchLabel)") }
    if target.isMissing { parts.append("directory not found") }
    if running { parts.append("running") }
    if hasActivity { parts.append("unread activity") }
    return parts.joined(separator: ", ")
  }
}

/// Collects each Workrooms tab chip's natural width for the drag gap math (issue #23).
private struct WorkroomTabWidthKey: PreferenceKey {
  static var defaultValue: [SidebarID: CGFloat] = [:]
  static func reduce(value: inout [SidebarID: CGFloat], nextValue: () -> [SidebarID: CGFloat]) {
    value.merge(nextValue()) { _, new in new }
  }
}
