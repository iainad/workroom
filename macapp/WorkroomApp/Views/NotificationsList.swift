import SwiftUI

/// The notifications history as a list, newest first — the shared body behind both the right-hand
/// inspector's Notifications section (`RightInspector`) and the menu bar popover
/// (`MenuBarNotificationsView`), so the rows look identical in both. There's no read state: tapping a row opens the terminal it came
/// from (`AppStore.openTerminal`, which also dismisses it), then runs `onActivate` so a host that
/// needs to close itself (the popover) can.
struct NotificationsList: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  /// Called after a row opens its terminal — lets the menu bar popover dismiss. The inspector,
  /// which stays open, passes nil.
  var onActivate: (() -> Void)?

  var body: some View {
    if notifications.items.isEmpty {
      // Compact, left-aligned, icon-first empty state (issue #24 feedback) — not the large
      // centered ContentUnavailableView.
      HStack(spacing: 6) {
        Image(systemName: "bell.slash").font(.callout).foregroundStyle(.tertiary)
        Text("No notifications").font(.callout).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("No notifications")
    } else {
      List {
        // Newest first; the store appends chronologically.
        ForEach(notifications.items.reversed()) { item in
          NotificationRow(item: item, flash: store.flashNotifID == item.id) {
            store.openTerminal(targetID: item.targetID, tabID: item.tabID, notifID: item.id)
            onActivate?()
          }
        }
      }
      .listStyle(.inset)
    }
  }
}

/// One notification row. Tapping opens the terminal it came from (`onOpen`). Carries a subtle
/// rounded hover fill — like the Changes panel's file rows (`ChangedFileRow`) — so it reads as the
/// clickable target it is; a plain `.buttonStyle(.plain)` row gave no hover feedback.
private struct NotificationRow: View {
  let item: WorkroomNotification
  /// True when this row just arrived while the inspector was open — flashes once to draw the eye
  /// (issue #31), mirroring the per-pane activity flash in `PaneLeafView`.
  var flash: Bool = false
  let onOpen: () -> Void
  @State private var hovering = false
  @State private var flashing = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: onOpen) {
      content
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 5).fill(rowFill)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: flashing)
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    // A new row mounts with `flash == true`; an already-mounted row flashes if the flag flips on.
    .onAppear { if flash { runFlash() } }
    .onChange(of: flash) { _, now in if now { runFlash() } }
  }

  /// Accent tint while flashing, else the usual subtle hover fill.
  private var rowFill: Color {
    flashing ? Color.accentColor.opacity(0.25) : Color.primary.opacity(hovering ? 0.08 : 0)
  }

  /// One-shot highlight: on, then off after a beat (mirrors `PaneLeafView`'s 0.6s flash).
  private func runFlash() {
    flashing = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { flashing = false }
  }

  // No read/unread state to indicate (read ⇒ dismissed), so there's no leading dot. A titleless
  // notification leads with its body rather than a placeholder; one with neither shows just its
  // source + time.
  private var content: some View {
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
  }
}
