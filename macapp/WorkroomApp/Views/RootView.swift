import AppKit
import Defaults
import SwiftUI

struct RootView: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  // Observed so the detail's workroom tab bar re-renders as terminals open/close (a tab appears when a
  // workroom gains its first terminal and disappears when it loses its last) — issue #23.
  @EnvironmentObject var terminals: TerminalSessions
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Default(.theme) private var theme
  /// Whether the right-hand notifications inspector is open. `@Default` (not `@State`) so the
  /// View-menu command (WorkroomCommands) toggles the same value.
  @Default(.showNotifications) private var showNotifications

  /// Drives the add-project importer — set from `store.requestAddProject`, which both ⌘O and the
  /// sidebar's Add-Project buttons raise. Hosted here (vs the sidebar) so the ⌘O command presents it
  /// even if the sidebar is collapsed via the standard toggle.
  @State private var showImporter = false

  /// Live preview of a workroom tab being dragged into the detail content to form a split (issue #23
  /// follow-up). Set by `WorkroomTabBar`'s drag, read by `WorkroomSplitView` to highlight the drop edge.
  @State private var workroomChipDrag: WorkroomPaneDrag?
  /// The detail content area's global frame, so a chip drag can be resolved against the workroom panes.
  @State private var detailContentFrame: CGRect = .zero

  /// True when the selected target can host a terminal right now: it exists, isn't missing,
  /// and isn't currently blocked by a running setup script.
  private var terminalInteractionAvailable: Bool {
    guard let target = store.selectedTarget, !target.isMissing else { return false }
    if store.logs[target.id]?.blocking == true { return false }
    return true
  }

  var body: some View {
    NavigationSplitView(
      columnVisibility: Binding(
        // Own the column visibility so the View ▸ Projects menu item can show a tick (the bar's
        // toggle, the auto-provided toolbar button, and a drag-collapse all round-trip through
        // `store.sidebarVisible`). `.detailOnly` is the only hidden state for a two-column split.
        get: { store.sidebarVisible ? .all : .detailOnly },
        set: { store.sidebarVisible = $0 != .detailOnly })
    ) {
      ProjectSidebar()
        .frame(minWidth: 240)
        // Persist the user-dragged sidebar width across launches (issue #14) via the
        // underlying NSSplitView's autosave — SwiftUI offers no width binding.
        .background(SplitViewAutosave(name: "WorkroomSidebarSplit"))
    } detail: {
      detail
    }
    .alert(
      store.errorTitle ?? "Something went wrong",
      isPresented: Binding(
        get: { store.errorMessage != nil },
        set: {
          if !$0 {
            store.errorMessage = nil
            store.errorTitle = nil
          }
        }
      )
    ) {
      Button("OK", role: .cancel) {
        store.errorMessage = nil
        store.errorTitle = nil
      }
    } message: {
      Text(store.errorMessage ?? "")
    }
    // Add-project importer + delete confirmation, re-homed here from ProjectSidebar (issue #23 OV1) so
    // the ⌘O / ⌘⌫ menu commands present reliably even when the sidebar is collapsed in Workrooms View.
    // The triggers stay on the store (`requestAddProject` / `pendingDeletion`), set by both the menu
    // commands and the sidebar's own buttons.
    .onChange(of: store.requestAddProject) { _, request in
      if request {
        showImporter = true
        store.requestAddProject = false
      }
    }
    .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result {
        Task { await store.addProject(url) }
      }
    }
    .confirmationDialog(
      store.pendingDeletion.map { "Delete '\($0.workroom.name)'?" } ?? "Delete workroom?",
      isPresented: Binding(
        get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let target = store.pendingDeletion {
          store.deleteWorkroom(target.workroom, in: target.project)
        }
        store.pendingDeletion = nil
      }
      Button("Cancel", role: .cancel) { store.pendingDeletion = nil }
    } message: {
      Text(
        "This removes the workroom's directory and runs its teardown script. For Git, the branch is left in place."
      )
    }
    // Top toolbar (issue #26): the back/forward chevrons (snug, one item) pinned to the leading
    // `.navigation` area beside the sidebar toggle; the notifications bell pinned to the trailing
    // `.primaryAction` area (where it opens the right-hand inspector). Both split-view level so
    // they're present even in the empty state — the detail toolbar's document actions (Open in…/
    // Reveal/Copy Path) only attach when a target is selected, and slot in before the bell.
    .toolbar {
      ToolbarItem(placement: .navigation) {
        HStack(spacing: 0) {
          Button {
            store.navigateBack()
          } label: {
            Image(systemName: "chevron.left")
          }
          .help("Back")
          .accessibilityLabel("Back")
          .disabled(!store.canGoBack)
          Button {
            store.navigateForward()
          } label: {
            Image(systemName: "chevron.right")
          }
          .help("Forward")
          .accessibilityLabel("Forward")
          .disabled(!store.canGoForward)
        }
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          showNotifications.toggle()
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "bell")
            UnreadBadge(count: notifications.total)
          }
        }
        .help("Notifications")
        .accessibilityLabel(
          notifications.total > 0
            ? "Notifications, \(notifications.total) unread" : "Notifications")
      }
    }
    .inspector(isPresented: $showNotifications) {
      NotificationsPanel(isOpen: showNotifications)
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
    .onAppear { applyAppearance() }
    .onChange(of: theme) { _ in applyAppearance() }
    // Keep the root branch labels reasonably current: refresh when the app regains
    // focus (throttled, so rapid alt-tabbing doesn't fork a git/jj process per project).
    // Regaining focus also dismisses the now-visible terminal's notifications (you're looking at it).
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      store.dismissFocusedTerminalNotifications()
      Task { await store.reloadIfStale() }
    }
    // Publish selection state for menu-command enablement (see WorkroomCommands). While a
    // setup script blocks the selected workroom's terminal, report false so ⌘T can't open
    // a (hidden) terminal behind the setup pane; the toolbar's Open/Reveal still work.
    .focusedSceneValue(\.workroomSelected, terminalInteractionAvailable)
    // Drive the "Next Notification" menu command's enabled state.
    .focusedSceneValue(\.hasNotifications, !notifications.items.isEmpty)
    // Drive the Go-menu Back/Forward commands' enabled state (issue #26).
    .focusedSceneValue(\.canNavigateBack, store.canGoBack)
    .focusedSceneValue(\.canNavigateForward, store.canGoForward)
    // Drive the Run/Stop/Restart menu items (issue #7). Run-state lives on the store (OV-A), so
    // these stay live as the command starts/stops/exits.
    .focusedSceneValue(\.hasRunCommand, selectedHasRunCommand)
    .focusedSceneValue(\.runCommandActive, selectedRunCommandActive)
    .focusedSceneValue(\.hasRunTerminal, store.hasAnyRunTerminal)
  }

  /// The project path of the selected root or workroom (nil for no selection) — the run command is
  /// configured per project and runnable from either (issue #7).
  private var selectedRunProjectPath: String? {
    AppStore.projectPath(of: store.selectedTargetID)
  }
  /// Whether the selected workroom's project has a run command configured.
  private var selectedHasRunCommand: Bool {
    guard let path = selectedRunProjectPath else { return false }
    return store.hasRunCommand(forProject: path)
  }
  /// Whether the selected target's run command is currently running.
  private var selectedRunCommandActive: Bool {
    guard let target = store.selectedTarget else { return false }
    return store.isRunCommandRunning(for: target.id)
  }

  /// Pushes the chosen appearance onto the running app. nil (System) tells AppKit to
  /// follow the OS appearance and keep tracking it. Terminals follow the appearance too, but
  /// only those currently in a window get AppKit's change hook — so sweep them all explicitly
  /// (see `TerminalSessions.applyThemeToAll`).
  private func applyAppearance() {
    NSApp.appearance = theme.nsAppearance
    store.terminals.applyThemeToAll()
  }

  @ViewBuilder
  private var detail: some View {
    // The workroom tab bar rides above the terminal whenever ≥1 workroom/root has a terminal (issue
    // #23). Tapping a tab selects that target, exactly like clicking it in the sidebar. It hides
    // entirely when nothing's open. The selected target's terminal shows below regardless of whether
    // it's among the tabs (e.g. a freshly selected workroom mounts its terminal, then a tab appears).
    // Opt-in: the `showWorkroomTabBar` setting (default off) gates it entirely. Read off the store
    // (a `@Published`, observed via `@EnvironmentObject`) so toggling it actually re-renders the
    // NavigationSplitView detail — a bare `@Default` read here didn't.
    let tabs = store.showWorkroomTabBar ? store.orderedWorkroomTargets() : []
    VStack(spacing: 0) {
      if !tabs.isEmpty {
        WorkroomTabBar(
          tabs: tabs, selectedID: store.selectedTargetID, onSelect: { selectWorkroomTab($0) },
          chipPaneDrag: $workroomChipDrag,
          localize: { workroomChipLocal($0) },
          dropTarget: { workroomChipDropTarget(at: $0) })
        Divider()
      }
      detailContent
        // The detail content's global frame, so a chip dragged from the bar can be resolved against the
        // workroom panes below it (issue #23 follow-up) — mirrors WorkroomTerminalsView ↔ TerminalTabStrip.
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: DetailContentFrameKey.self, value: geo.frame(in: .global))
          }
        )
    }
    .onPreferenceChange(DetailContentFrameKey.self) { detailContentFrame = $0 }
  }

  /// The content-local point for a chip drag at `global`, or nil when the cursor is still over the bar
  /// (→ a reorder, not a drop-into-content).
  private func workroomChipLocal(_ global: CGPoint) -> CGPoint? {
    guard detailContentFrame.contains(global) else { return nil }
    return CGPoint(x: global.x - detailContentFrame.minX, y: global.y - detailContentFrame.minY)
  }

  /// The layout a chip drop targets: the active split, or a single `.leaf(selected)` so the first drop
  /// onto the lone visible pane seeds a split.
  private func workroomDropLayout() -> PaneLayout<SidebarID>? {
    if let split = store.workroomSplit { return split }
    if let sid = store.selectedTargetID { return .leaf(sid) }
    return nil
  }

  /// Where a chip dropped at `global` lands (workroom pane + edge), using the same plan the renderer
  /// uses, or nil if it isn't over a pane.
  private func workroomChipDropTarget(at global: CGPoint) -> (sid: SidebarID, edge: PaneEdge)? {
    guard let local = workroomChipLocal(global), let layout = workroomDropLayout() else {
      return nil
    }
    let plan = PaneTreeLayout.plan(layout, in: CGRect(origin: .zero, size: detailContentFrame.size))
    guard let hit = PaneTreeLayout.dropTarget(at: local, panes: plan.panes) else { return nil }
    return (sid: hit.tab, edge: hit.edge)
  }

  /// Focus a workroom tab — mirrors `ProjectSidebar`'s selection setter (sets both the target and the
  /// New-Workroom project context), so every selection-driven command targets the focused workroom.
  /// Clicking a tab that isn't a current split member returns to a single view of it (dissolve the
  /// split); clicking a member just focuses it, keeping the split — the renderer keys the focused pane
  /// on `selectedTargetID`, so the focused member must always be a leaf of what's rendered (issue #23 T2).
  private func selectWorkroomTab(_ sid: SidebarID) {
    if let split = store.workroomSplit, !split.contains(sid) { store.dissolveWorkroomSplit() }
    store.selectedTargetID = sid
    store.selectedProjectID = AppStore.projectPath(of: sid)
  }

  @ViewBuilder
  private var detailContent: some View {
    if let target = store.selectedTarget {
      if target.isMissing {
        ContentUnavailableView(
          "Directory not found",
          systemImage: "questionmark.folder",
          description: Text(
            "\(target.title) points at a path that no longer exists.\n\(target.path)")
        )
      } else {
        // The focused target's terminal body. When the tab bar is on we ALWAYS route through
        // `WorkroomSplitView` (a no-split case is just `.leaf(selected)`), so single↔split is a leaf-set
        // change — never a structural swap that would re-parent the surface and blank a pane (issue #23
        // T1, the same lesson as `WorkroomTerminalsView` always rendering through `PaneTreeView`). The
        // title/toolbar are shared here and follow the focused member (`selectedTarget`).
        Group {
          if store.showWorkroomTabBar {
            workroomSplitBody(focused: target)
          } else {
            targetTerminalBody(target)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(target.title)
        .navigationSubtitle(target.path)
        .toolbar {
          // Run/Stop/Restart for the selected root OR workroom (issue #7): the command is configured
          // per project and both targets have a project path + a directory to run in. `projectPath(of:)`
          // resolves for `.root`/`.workroom`, nil for a bare `.project` (never shown in the detail pane).
          if let projectPath = AppStore.projectPath(of: store.selectedTargetID) {
            RunCommandToolbar(target: target, projectPath: projectPath)
          }
          TargetDetailToolbar(path: target.path)
        }
      }
    } else {
      ContentUnavailableView(
        "Nothing selected",
        systemImage: "terminal",
        description: Text(
          "Select a project's root or a workroom to open a terminal in its directory, or create one."
        )
      )
      // Nothing selected → nothing to title, so drop the toolbar bar/separator and the
      // window title for a clean empty state.
      .navigationTitle("")
      .toolbarBackground(.hidden, for: .windowToolbar)
    }
  }

  /// The workroom body when the tab bar is on: always `WorkroomSplitView`, with the layout being the
  /// active split or a single `.leaf(selected)` (issue #23 T1). One render path → no reparent on
  /// single↔split. Falls back to the bare terminal body if somehow there's no selection id.
  @ViewBuilder
  private func workroomSplitBody(focused: TerminalTarget) -> some View {
    if let selected = store.selectedTargetID {
      WorkroomSplitView(
        layout: store.workroomSplit ?? .leaf(selected),
        resolve: { store.target(for: $0) },
        focusedID: selected,
        externalDrag: workroomChipDrag,
        onFocus: { selectWorkroomTab($0) },
        onSetRatio: { store.setWorkroomSplitRatio($0, forSplit: $1) },
        onClose: { store.removeWorkroomSplitMember($0) }
      )
    } else {
      targetTerminalBody(focused)
    }
  }

  /// One target's terminal ZStack with its setup log (if any). While a setup script runs
  /// (`log.blocking`), the log floats over the pane and the terminal is withheld — `WorkroomTerminalsView`
  /// mounts (and `.task` creates the first terminal) only once the blocking log is dismissed. Only
  /// workrooms ever have a log; for a root, `logs[target.id]` is nil. Title/toolbar are owned by the
  /// caller (shared with the split path), so this is just the body.
  @ViewBuilder
  private func targetTerminalBody(_ target: TerminalTarget) -> some View {
    let isBlocking = store.logs[target.id]?.blocking == true
    ZStack {
      if !isBlocking {
        VStack(spacing: 0) {
          WorkroomTerminalsView(target: target, sessions: store.terminals)

          if let log = store.logs[target.id] {
            Divider()
            ScriptLogPanel(session: log) { store.logs[target.id] = nil }
          }
        }
      }

      if let log = store.logs[target.id], log.blocking {
        SetupOverlay(session: log) {
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            store.logs[target.id] = nil
          }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        .zIndex(1)
      }
    }
  }
}

/// The detail content area's global frame, published so `WorkroomTabBar`'s chip drag can localise a
/// cursor point against the workroom panes below the bar (issue #23 follow-up). Mirrors
/// `ContentFrameKey` in `WorkroomTerminalsView`, one level up.
private struct DetailContentFrameKey: PreferenceKey {
  static var defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}
