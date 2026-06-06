import SwiftUI

/// The detail pane's terminals for one target (a workroom or a project root): a horizontal
/// tab strip below the title bar plus the active terminal. Observes `TerminalSessions` so
/// adding, closing, and switching tabs all update live.
struct WorkroomTerminalsView: View {
  let target: TerminalTarget
  @ObservedObject var sessions: TerminalSessions
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

  private let tabSpacing: CGFloat = 4

  var body: some View {
    let tabs = sessions.tabs(for: target)
    let active = sessions.activeTab(for: target)
    // The terminal (or empty state) fills the pane; the tab bar rides on safeAreaInset so it only
    // ever takes its natural height — otherwise the tab bar's horizontal ScrollView grabs the
    // vertical slack when there's no terminal below it and balloons.
    Group {
      if let active {
        TerminalContainerView(view: active.view)
          .id(active.id)  // re-mount when the active tab changes
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
    // Create the first terminal once the pane appears (and for each new target).
    .task(id: target.id) { sessions.ensureTab(for: target) }
    // Focusing a terminal clears its unread. This view only ever renders the selected target's
    // active terminal, so `active.id` changing *is* a focus change — whether from a chip tap,
    // ⌘1–9, the sidebar switching targets, or a close revealing a neighbour. One hook covers
    // them all; `initial` handles the target's first appearance (e.g. arriving from the empty
    // state with unread already waiting). Returning to the app with the same tab still focused
    // is handled separately by RootView's didBecomeActive → markFocusedTerminalRead.
    .onChange(of: active?.id, initial: true) { _, id in
      if let id { notifications.markRead(tab: id) }
    }
    // Drive the "Close Terminal" menu command's enabled state.
    .focusedSceneValue(\.hasTerminal, !tabs.isEmpty)
  }

  private func tabBar(_ tabs: [TerminalTab], activeID: TerminalTab.ID?) -> some View {
    // Resolve the drag once per layout: which tab is dragging, and where it would land.
    let draggedIndex = draggingID.flatMap { id in tabs.firstIndex { $0.id == id } }
    let dropTarget = draggedIndex.map { dropTargetIndex(tabs, draggedIndex: $0) }
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
    let showClose = hoveredTab == tab.id && draggingID == nil
    // Activity in an unfocused tab highlights the tab itself (accent title + faint accent
    // fill) instead of a count — a tab is too narrow for a number.
    let hasUnread = notifications.unread(tab: tab.id) > 0
    return Text(tab.title)
      .font(.callout)
      .lineLimit(1)
      .foregroundStyle(hasUnread ? Color.accentColor : Color.primary)
      // On hover, fade the title's right edge so the close button — overlaid on top of
      // the text and taking no layout space — reads cleanly.
      .mask(
        HStack(spacing: 0) {
          Rectangle()
          LinearGradient(
            stops: [
              .init(color: .black, location: 0),
              .init(color: showClose ? .clear : .black, location: 0.45),
              .init(color: showClose ? .clear : .black, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: 46)
        }
      )
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      .overlay(alignment: .trailing) {
        TabCloseButton {
          sessions.closeTab(tab.id, for: target)
        }
        .help("Close \(tab.title)")
        .accessibilityLabel("Close \(tab.title)")
        .opacity(showClose ? 1 : 0)
        .allowsHitTesting(showClose)
        .padding(.trailing, 4)
      }
      // Subtle highlight for active/hover; a solid lifted chip while dragging.
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.primary.opacity(isActive ? 0.1 : (showClose ? 0.05 : 0)))
      }
      // Unread activity tints the whole tab with the accent color (pairs with the accent title).
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(Color.accentColor.opacity(hasUnread ? 0.15 : 0))
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
          }
          .onEnded { _ in commitDrag() }
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
