import AppKit
import Defaults
import SwiftUI

struct RootView: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Default(.theme) private var theme
  /// Whether the right-hand notifications inspector is open. `@Default` (not `@State`) so the
  /// View-menu command (WorkroomCommands) toggles the same value.
  @Default(.showNotifications) private var showNotifications

  /// True when the selected target can host a terminal right now: it exists, isn't missing,
  /// and isn't currently blocked by a running setup script.
  private var terminalInteractionAvailable: Bool {
    guard let target = store.selectedTarget, !target.isMissing else { return false }
    if store.logs[target.id]?.blocking == true { return false }
    return true
  }

  var body: some View {
    NavigationSplitView {
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
    if let target = store.selectedTarget {
      if target.isMissing {
        ContentUnavailableView(
          "Directory not found",
          systemImage: "questionmark.folder",
          description: Text(
            "\(target.title) points at a path that no longer exists.\n\(target.path)")
        )
      } else {
        targetDetail(target)
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

  /// A target's terminal (root or workroom), with its setup log (if any). While a setup
  /// script runs (`log.blocking`), the log floats in a panel *over* the main pane and the
  /// terminal is withheld; otherwise a finished/legacy log docks beneath the terminal.
  /// Only workrooms ever have a log; for a root, `logs[target.id]` is always nil. The
  /// title/toolbar live on the outer container so they stay put across the transition.
  @ViewBuilder
  private func targetDetail(_ target: TerminalTarget) -> some View {
    let isBlocking = store.logs[target.id]?.blocking == true
    ZStack {
      // Base pane. While setup blocks the terminal, WorkroomTerminalsView is withheld so no
      // terminal is created — it mounts (and `.task` creates the first one) only once the
      // blocking log is cleared on Dismiss, revealing the terminal beneath the fading panel.
      if !isBlocking {
        VStack(spacing: 0) {
          WorkroomTerminalsView(target: target, sessions: store.terminals)

          if let log = store.logs[target.id] {
            Divider()
            ScriptLogPanel(session: log) { store.logs[target.id] = nil }
          }
        }
      }

      // Setup log, floating over the main pane (as if over the terminal).
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(target.title)
    .navigationSubtitle(target.path)
    .toolbar {
      // Run/Stop/Restart for the selected root OR workroom (issue #7): the command is configured per
      // project and both targets have a project path + a directory to run in (the root runs it in the
      // project directory itself). `projectPath(of:)` resolves for `.root`/`.workroom`, nil for a bare
      // `.project` (never shown in the detail pane).
      if let projectPath = AppStore.projectPath(of: store.selectedTargetID) {
        RunCommandToolbar(target: target, projectPath: projectPath)
      }
      TargetDetailToolbar(path: target.path)
    }
  }
}
