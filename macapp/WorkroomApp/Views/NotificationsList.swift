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
      // A plain `VStack`, not a `List` or a `ScrollView`: the inspector pane hosts this body inside
      // a native `NSScrollView` (`InspectorSplitView`) that does the scrolling and sizes itself to
      // the body's *natural* height. A `List`/`ScrollView` is a greedy scroll container with no
      // finite intrinsic height, so nesting one here collapses the body and clips the rows. A `List`
      // also clips its first row under a built-in top inset, forces a minimum row margin, and paints
      // its own (light) background. A transparent `VStack` gives exact control over the row
      // margins/spacing and lets the themed inspector background show through — matching the
      // Changes/PR panels, which are built the same way.
      VStack(spacing: 0) {
        // Newest first; the store appends chronologically.
        ForEach(notifications.items.reversed()) { item in
          NotificationRow(item: item, flash: store.flashNotifID == item.id) {
            store.openTerminal(targetID: item.targetID, tabID: item.tabID, notifID: item.id)
            onActivate?()
          }
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 6)
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
  private let theme = ThemeService.shared

  var body: some View {
    Button(action: onOpen) {
      content
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
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

  /// Shared abbreviated relative formatter ("2 min. ago", "just now").
  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
  }()

  /// An approximate "time ago" string for `date`. Under ~10s reads "just now" rather than a jittery
  /// "0 sec. ago".
  static func timeAgo(_ date: Date) -> String {
    if Date().timeIntervalSince(date) < 10 { return "just now" }
    return relativeFormatter.localizedString(for: date, relativeTo: Date())
  }

  /// Accent tint while flashing, else the usual subtle hover fill.
  private var rowFill: Color {
    flashing ? theme.tokens.accent.opacity(0.25) : theme.tokens.hover.opacity(hovering ? 1 : 0)
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
          // A static approximate "time ago" (e.g. "2 min. ago"), not the ticking `.relative` timer
          // that counted up second-by-second. Recomputed whenever the list re-renders.
          Text(Self.timeAgo(item.date))
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 0)
    }
  }
}
