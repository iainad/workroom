import SwiftUI

/// The displayed form of an unread count, capped at `99+`. Pure so the badge and the menu bar item
/// share one cap and can't drift (mirrors `NotificationGate`'s extract-and-test seam).
enum UnreadCount {
  static func label(_ count: Int) -> String { count > 99 ? "99+" : "\(count)" }
}

/// A small unread-count pill. Used by the toolbar button (a single aggregate total reads well as
/// a number). Renders nothing when `count` is 0.
struct UnreadBadge: View {
  let count: Int
  private let theme = ThemeService.shared

  var body: some View {
    if count > 0 {
      Text(UnreadCount.label(count))
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(theme.tokens.accentForeground)
        .monospacedDigit()
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(theme.tokens.accent))
        .accessibilityLabel("\(count) unread")
    }
  }
}

/// A small accent dot marking unread activity, used on sidebar rows (project / root / workroom)
/// where a count is too noisy — presence is what matters. Renders nothing when `count` is 0.
struct UnreadDot: View {
  let count: Int
  private let theme = ThemeService.shared

  var body: some View {
    if count > 0 {
      Circle()
        .fill(theme.tokens.accent)
        .frame(width: 7, height: 7)
        .accessibilityLabel("Unread notifications")
    }
  }
}
