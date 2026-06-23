import Defaults
import SwiftUI

/// The trailing title-bar controls — the notifications bell (with unread badge) and the inspector
/// toggle — built as a plain SwiftUI `HStack` and hosted via `TitlebarAccessory`.
///
/// Why not `.toolbar`: in a `NavigationSplitView`, `.toolbar`'s `.primaryAction` is *column-scoped*
/// ("trailing edge of *this column*", which docks to the sidebar), and within a placement the only
/// ordering lever is declaration order. These two controls previously had to be split across two
/// separate toolbars to land near the right edge (see the history in `RootView`). Hosting them in a
/// title-bar accessory instead gives one `HStack` with exact spacing, a divider, and a fixed order,
/// pinned to the window's true trailing edge regardless of the split's columns.
///
/// The two controls do different things: the bell opens the *oldest* pending notification's terminal
/// (and dismisses it — repeated clicks walk the backlog oldest→newest, mirroring the ⇧⌘N "Next
/// Notification" command); the `sidebar.right` toggle shows/hides the notifications inspector, filling
/// while open like the leading sidebar toggle. The bell is disabled when there are none to open.
struct TitlebarControlsBar: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Default(.showNotifications) private var showNotifications
  private let theme = ThemeService.shared

  /// The bell's accessibility label, factored out so the call site stays a single short line
  /// (a wrapped multi-line `.accessibilityLabel(…)` argument trips swift-format's line-break rule).
  private static func bellLabel(unread: Int) -> String {
    unread > 0 ? "Notifications, \(unread) unread" : "Notifications"
  }

  var body: some View {
    HStack(spacing: 10) {
      // Hairline divider separating the bell from the controls to its left (quick terminal / run /
      // open-in). Moved here from between the bell and the inspector toggle, which now read as one group.
      Rectangle()
        .fill(theme.tokens.border)
        .frame(width: 1, height: 14)

      // Notifications bell with live unread badge — opens the oldest pending notification's terminal.
      Button {
        store.openOldestNotification()
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "bell")
          UnreadBadge(count: notifications.total)
        }
      }
      .disabled(notifications.total == 0)
      .help(notifications.total > 0 ? "Open oldest notification" : "No notifications")
      .accessibilityLabel(Self.bellLabel(unread: notifications.total))
      .accessibilityIdentifier("titlebar.notifications")

      // Inspector toggle — fills while the inspector is open so the on/off state reads at a glance,
      // mirroring the leading sidebar toggle.
      Button {
        showNotifications.toggle()
      } label: {
        Image(systemName: "sidebar.right")
          .symbolVariant(showNotifications ? .fill : .none)
      }
      .help(showNotifications ? "Hide right sidebar" : "Show right sidebar")
      .accessibilityLabel("Right sidebar")
      .accessibilityValue(showNotifications ? "shown" : "hidden")
      .accessibilityIdentifier("titlebar.toggleInspector")
      // Hovering this button (while the inspector is collapsed) peeks it via the edge-reveal overlay
      // (issue #74) — the trigger is the button alone, mirroring the leading sidebar toggle. Only
      // report while collapsed so a hover with the inspector open doesn't churn reveal state.
      .onHover { hovering in
        if !showNotifications { store.hoveringRightToggle = hovering }
      }
    }
    .buttonStyle(ToolbarIconButtonStyle())
    // No leading padding: the leading divider above is the bar's first element, and the gap to its
    // left comes from TrailingTitlebarBar's 6pt HStack spacing. A leading 10 here would stack on top.
    // Trailing 10 keeps the inspector toggle off the window edge.
    .padding(.trailing, 10)
    // Fill the full-height (52pt) accessory host so the HStack centres its buttons — see LeadingTitlebarBar.
    .frame(maxHeight: .infinity)
  }
}
