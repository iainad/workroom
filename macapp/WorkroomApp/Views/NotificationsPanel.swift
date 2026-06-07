import SwiftUI

/// Namespacing for the notifications inspector's shared open/closed state. Backed by
/// `@AppStorage` so both `RootView` (the inspector + toolbar toggle) and `WorkroomCommands`
/// (the View-menu item) drive the same value.
enum NotificationsInspector {
  static let storageKey = "showNotificationsInspector"
}

/// The right-hand notifications inspector (`.inspector`, macOS 14): the session history, newest
/// first. There's no read state — tapping an item opens the terminal it came from
/// (`AppStore.openTerminal`) and dismisses it; the panel only ever shows pending notifications.
struct NotificationsPanel: View {
  /// Whether the inspector is presented. SwiftUI keeps inspector toolbar contributions alive
  /// while collapsed, so the buttons are gated on this.
  let isOpen: Bool
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore

  var body: some View {
    // The content fills the inspector; the actions live in the inspector's own toolbar strip
    // (its natural top). Individual ToolbarItems (not a group) render as flat icon buttons with
    // no pill; `.primaryAction` right-aligns them. Putting them here also claims the inspector's
    // toolbar slice, which keeps the detail-pane toolbar items (Open in…, Reveal, Copy Path)
    // above the main content instead of bleeding over this sidebar — and leaves no empty strip.
    content
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

  @ViewBuilder
  private var content: some View {
    if notifications.items.isEmpty {
      ContentUnavailableView {
        Label("No notifications", systemImage: "bell.slash")
      }
    } else {
      List {
        // Newest first; the store appends chronologically.
        ForEach(notifications.items.reversed()) { item in
          Button {
            store.openTerminal(targetID: item.targetID, tabID: item.tabID, notifID: item.id)
          } label: {
            row(item)
          }
          .buttonStyle(.plain)
        }
      }
      .listStyle(.inset)
    }
  }

  private func row(_ item: WorkroomNotification) -> some View {
    // No read/unread state to indicate (read ⇒ dismissed), so there's no leading dot. A titleless
    // notification leads with its body rather than a placeholder; one with neither shows just its
    // source + time.
    let headline = item.title.isEmpty ? (item.body ?? "") : item.title
    let subtext = item.title.isEmpty ? nil : item.body
    return HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        if !headline.isEmpty {
          HStack(spacing: 4) {
            Text(headline)
              .font(.callout)
              .fontWeight(.semibold)
              .lineLimit(1)
            if item.count > 1 {
              Text("×\(item.count)").font(.caption2).foregroundStyle(.secondary)
            }
          }
        }
        if let subtext, !subtext.isEmpty {
          Text(subtext).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        HStack(spacing: 4) {
          if !item.source.isEmpty {
            Text(item.source).lineLimit(1)
            Text("·")
          }
          Text(item.date, style: .relative)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
  }
}
