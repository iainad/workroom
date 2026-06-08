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
    // The notifications inspector + its toolbar toggle live at the split-view level so they're
    // available even when nothing is selected (a backgrounded terminal can fire any time).
    .toolbar {
      ToolbarItem {
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
    // Drive the "Go to Next Notification" menu command's enabled state.
    .focusedSceneValue(\.hasNotifications, !notifications.items.isEmpty)
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
      TargetDetailToolbar(path: target.path)
    }
  }
}
