import SwiftUI

/// The single unified title-bar toolbar, split into a leading and a trailing half hosted as
/// `NSTitlebarAccessoryViewController`s (see `TitlebarAccessory`). They sit in the window's *one*
/// title-bar row — the leading half right after the traffic lights, the trailing half at the
/// window's true trailing edge — so together they span the full width with the draggable title-bar
/// gap between them.
///
/// Why accessories rather than `.toolbar`: SwiftUI's `.toolbar` placement is column-scoped in a
/// `NavigationSplitView` (`.primaryAction` docks to a column, not the window edge), and `.toolbar`
/// items render with the framework's own chrome. Hosting plain SwiftUI `HStack`s in title-bar
/// accessories instead gives every control one shared `.borderless` style and exact placement,
/// independent of the split's columns.

/// A hairline group separator shared by the title-bar bars (matches `TitlebarControlsBar`'s).
struct TitlebarDivider: View {
  private let theme = ThemeService.shared

  var body: some View {
    Rectangle()
      .fill(theme.tokens.border)
      .frame(width: 1, height: 14)
      .padding(.horizontal, 4)
  }
}

/// Leading title-bar controls: sidebar toggle + history nav (issue #26). Our
/// own sidebar toggle (leftmost, right after the traffic lights) replaces NavigationSplitView's auto
/// one — removed via `.toolbar(removing:)`, with the now-itemless window toolbar hidden in
/// `WindowBackgroundThemer` so it doesn't leave an overflow chevron.
struct LeadingTitlebarBar: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var updater: Updater

  var body: some View {
    HStack(spacing: 6) {
      Button {
        store.sidebarVisible.toggle()
      } label: {
        Image(systemName: "sidebar.left")
      }
      .help(store.sidebarVisible ? "Hide sidebar" : "Show sidebar")
      .accessibilityLabel("Toggle sidebar")
      .accessibilityIdentifier("toolbar.toggleSidebar")
      // Hovering this button (while the sidebar is collapsed) peeks the sidebar via the edge-reveal
      // overlay (issue #74) — the trigger is the button alone, never the toolbar strip that used to
      // sit above the workroom tabs. Only report while collapsed so a hover with the sidebar pinned
      // doesn't churn reveal state.
      .onHover { hovering in
        if !store.sidebarVisible { store.hoveringLeftToggle = hovering }
      }

      TitlebarDivider()

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

      // A newer version is waiting (Sparkle gentle reminder) — a highlighted pill, right of the
      // history nav. Self-hides when no update is pending; the divider matches.
      if updater.availableVersionString != nil {
        TitlebarDivider()
        UpdateAvailableButton()
      }
    }
    .buttonStyle(ToolbarIconButtonStyle())
    .padding(.horizontal, 10)
    // The titlebar accessory host is the full title-bar height (52pt — NOT 28), and NSHostingView
    // top-aligns a fixed-height root inside it, so the icons sat high. Fill the host and let the HStack
    // centre its buttons on the traffic-light line (the close button centres at y=26 of the 52pt host).
    .frame(maxHeight: .infinity)
  }
}

/// Trailing title-bar controls: the quick terminal (issue #39), the selected target's run/open-in
/// actions (issue #7), plus the notifications bell + inspector toggle. `RunControls`/`OpenInControl`
/// render nothing when not applicable, so the group collapses to just quick terminal + bell + toggle
/// in the empty state.
struct TrailingTitlebarBar: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore

  var body: some View {
    HStack(spacing: 6) {
      // Quick Terminal (⌥§) — a ~/ shell in its own window. Leftmost in the trailing group, just left
      // of the run controls. Always present (independent of the selection), so it leads the group.
      Button {
        NotificationCenter.default.post(name: .showQuickTerminal, object: nil)
      } label: {
        // The `.badge.plus` extends this glyph's box upward, so a plain centre sits ~0.5pt high vs the
        // other icons; nudge it down to sit on the same line.
        Image(systemName: "macwindow.badge.plus")
          .offset(y: 0.5)
      }
      .help("Quick Terminal (⌥§)")
      .accessibilityLabel("Quick Terminal")
      .accessibilityIdentifier("toolbar.quickTerminal")

      if let target = store.selectedTarget, !target.isMissing {
        // Separate the quick terminal from the target's run/open-in actions — a different group.
        TitlebarDivider()
        if let projectPath = AppStore.projectPath(of: store.selectedTargetID) {
          RunControls(target: target, projectPath: projectPath)
        }
        OpenInControl(path: target.path)
      }
      // Bell + inspector toggle (carries its own padding/divider/style).
      TitlebarControlsBar()
    }
    .buttonStyle(ToolbarIconButtonStyle())
    // Fill the full-height (52pt) accessory host so the HStack centres its buttons — see LeadingTitlebarBar.
    .frame(maxHeight: .infinity)
  }
}
