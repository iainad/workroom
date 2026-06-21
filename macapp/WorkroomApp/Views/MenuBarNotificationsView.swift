import SwiftUI

/// The menu bar item's popover (issue #33): just the shared `NotificationsList`. The
/// `MenuBarController` only opens this when there *are* notifications (an empty click focuses the app
/// instead), but it still falls back to a "No notifications" state for the brief window where the
/// count drains while the popover is open. No header or Clear button (clearing lives in the in-app
/// inspector); tapping a row opens its terminal (which activates the app) and then closes the popover
/// via `onClose` — passed in by the controller, since `@Environment(\.dismiss)` is inert in a
/// hand-hosted `NSPopover`.
struct MenuBarNotificationsView: View {
  /// The app-level registry (issue #70). The popover shows the active window's notifications and
  /// routes taps within that window; the menu-bar/Dock *count* aggregates across all windows.
  @ObservedObject var registry: WindowRegistry
  /// Closes the hosting popover (wired to `NSPopover.performClose` by `MenuBarController`).
  let onClose: () -> Void

  var body: some View {
    Group {
      if let store = registry.lastActiveStore {
        // A ScrollView so the rows stack from the top (the fixed-height frame would otherwise
        // center the shorter-than-360 list) and a long list scrolls instead of clipping.
        ScrollView {
          NotificationsList(onActivate: onClose)
            .environmentObject(store)
            .environmentObject(store.notifications)
        }
      } else {
        HStack(spacing: 6) {
          Image(systemName: "bell.slash").font(.callout).foregroundStyle(.tertiary)
          Text("No notifications").font(.callout).foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: 320, height: 360, alignment: .top)
  }
}
