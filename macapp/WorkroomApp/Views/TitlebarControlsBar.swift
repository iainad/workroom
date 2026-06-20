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
/// Both controls toggle the same notifications inspector: the bell carries the unread count and
/// reads as the notification-center entry; the `sidebar.right` toggle fills while the inspector is
/// open, mirroring the leading sidebar toggle (the conventional show/hide affordance).
struct TitlebarControlsBar: View {
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
      // Notifications bell with live unread badge.
      Button {
        showNotifications.toggle()
      } label: {
        HStack(spacing: 3) {
          Image(systemName: "bell")
          UnreadBadge(count: notifications.total)
        }
      }
      .help("Notifications")
      .accessibilityLabel(Self.bellLabel(unread: notifications.total))
      .accessibilityIdentifier("titlebar.notifications")

      // Hairline divider grouping the bell with the inspector toggle.
      Rectangle()
        .fill(theme.tokens.border)
        .frame(width: 1, height: 14)

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
    }
    .buttonStyle(ToolbarIconButtonStyle())
    // No leading padding: the bell's left divider lives in TrailingTitlebarBar (its 4pt pad + the bar's
    // 6pt spacing already give a 10pt gap to the bell). A leading 10 here would stack on top, leaving
    // the bell with a wider gap on its left than its right (the 10pt HStack spacing to its right
    // divider). Trailing 10 keeps the inspector toggle off the window edge.
    .padding(.trailing, 10)
    // Fill the full-height (52pt) accessory host so the HStack centres its buttons — see LeadingTitlebarBar.
    .frame(maxHeight: .infinity)
  }
}
