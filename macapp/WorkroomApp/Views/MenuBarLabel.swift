import SwiftUI

/// The `MenuBarExtra`'s status-bar label (issue #33): the monochrome Workroom glyph, plus the
/// pending count when there is one. `MenuBarExtra` rasterises the label as a template image, so the
/// glyph follows the menu bar's appearance (and dims when the app is inactive) and the count renders
/// in the menu bar's text colour beside it. Observing the store here (not in the non-View `App`)
/// is what makes the menu bar item update live as notifications arrive and clear.
struct MenuBarLabel: View {
  @ObservedObject var notifications: NotificationCenterStore

  var body: some View {
    let total = notifications.total
    if total > 0 {
      HStack(spacing: 3) {
        Image("MenuBarIcon")
        Text(UnreadCount.label(total)).monospacedDigit()
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Workroom, \(total) notifications")
    } else {
      Image("MenuBarIcon")
        .accessibilityLabel("Workroom notifications")
    }
  }
}
