import SwiftUI

/// Namespacing for the notifications inspector's shared open/closed state. Backed by
/// `@AppStorage` so both `RootView` (the inspector + toolbar toggle) and `WorkroomCommands`
/// (the View-menu item) drive the same value.
enum NotificationsInspector {
  static let storageKey = "showNotificationsInspector"
}

/// The right-hand notifications inspector (`.inspector`, macOS 14): the full session history,
/// newest first, with read/unread state. Tapping an item opens the terminal it came from
/// (`AppStore.openTerminal`), which also marks that item read.
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
          ToolbarItem(placement: .primaryAction) {
            Button {
              notifications.markAllRead()
            } label: {
              Image(systemName: "checkmark.circle")
            }
            .help("Mark all read")
            .disabled(!notifications.hasUnread)
          }
          ToolbarItem(placement: .primaryAction) {
            Button {
              notifications.clear()
            } label: {
              Image(systemName: "trash")
            }
            .help("Clear")
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
      } description: {
        Text("Activity in unfocused terminals (OSC 9/99/777 or the bell) shows up here.")
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
    HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(item.isRead ? Color.clear : Color.accentColor)
        .frame(width: 7, height: 7)
        .padding(.top, 5)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 4) {
          Text(item.title)
            .font(.callout)
            .fontWeight(item.isRead ? .regular : .semibold)
            .lineLimit(1)
          if item.count > 1 {
            Text("×\(item.count)").font(.caption2).foregroundStyle(.secondary)
          }
        }
        if let body = item.body, !body.isEmpty {
          Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
    // Read notifications recede; unread stay full-strength.
    .opacity(item.isRead ? 0.5 : 1)
  }
}
