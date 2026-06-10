import SwiftUI

/// The menu bar item's popover (`MenuBarExtra` `.window` style, issue #33): just the shared
/// `NotificationsList` — the notifications if any, otherwise the "No notifications" empty state. No
/// header or Clear button (clearing lives in the in-app inspector); tapping a row opens its terminal
/// (which activates the app) and then dismisses this window via `onActivate`.
struct MenuBarNotificationsView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NotificationsList(onActivate: { dismiss() })
      .frame(width: 320, height: 360)
  }
}
