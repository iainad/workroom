import SwiftUI

/// The right-hand notifications inspector (`.inspector`, macOS 14): the session history, newest
/// first. There's no read state — tapping an item opens the terminal it came from
/// (`AppStore.openTerminal`) and dismisses it; the panel only ever shows pending notifications.
struct NotificationsPanel: View {
  /// Whether the inspector is presented. SwiftUI keeps inspector toolbar contributions alive
  /// while collapsed, so the buttons are gated on this.
  let isOpen: Bool
  @EnvironmentObject var notifications: NotificationCenterStore

  var body: some View {
    // The content fills the inspector; the actions live in the inspector's own toolbar strip
    // (its natural top). Individual ToolbarItems (not a group) render as flat icon buttons with
    // no pill; `.primaryAction` right-aligns them. Putting them here also claims the inspector's
    // toolbar slice, which keeps the detail-pane toolbar items (Open in…, Reveal, Copy Path)
    // above the main content instead of bleeding over this sidebar — and leaves no empty strip.
    NotificationsList()
      .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
      .toolbar {
        if isOpen {
          // Just "Clear": with no read state, dismissing everything *is* clearing, so the former
          // "Mark all read" button would be a duplicate.
          ToolbarItem(placement: .primaryAction) {
            Button {
              notifications.clear()
            } label: {
              Image(systemName: "trash")
            }
            .help("Clear")
            .accessibilityLabel("Clear notifications")
            .disabled(notifications.items.isEmpty)
          }
        }
      }
  }
}
