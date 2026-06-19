import SwiftUI

/// The menu bar item's popover (`MenuBarExtra` `.window` style, issue #33): just the shared
/// `NotificationsList` — the notifications if any, otherwise the "No notifications" empty state. No
/// header or Clear button (clearing lives in the in-app inspector); tapping a row opens its terminal
/// (which activates the app) and then dismisses this window via `onActivate`.
struct MenuBarNotificationsView: View {
  /// The app-level registry (issue #70). The popover shows the active window's notifications and
  /// routes taps within that window; the menu-bar/Dock *count* aggregates across all windows.
  @ObservedObject var registry: WindowRegistry
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Group {
      if let store = registry.lastActiveStore {
        NotificationsList(onActivate: { dismiss() })
          .environmentObject(store)
          .environmentObject(store.notifications)
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
    .frame(width: 320, height: 360)
  }
}
