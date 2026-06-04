import SwiftUI

/// A small unread-count pill. Used by the toolbar button (a single aggregate total reads well as
/// a number). Renders nothing when `count` is 0.
struct UnreadBadge: View {
  let count: Int

  var body: some View {
    if count > 0 {
      Text(count > 99 ? "99+" : "\(count)")
        .font(.caption2)
        .fontWeight(.semibold)
        .foregroundStyle(.white)
        .monospacedDigit()
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.accentColor))
        .accessibilityLabel("\(count) unread")
    }
  }
}

/// A small accent dot marking unread activity, used on sidebar rows (project / root / workroom)
/// where a count is too noisy — presence is what matters. Renders nothing when `count` is 0.
struct UnreadDot: View {
  let count: Int

  var body: some View {
    if count > 0 {
      Circle()
        .fill(Color.accentColor)
        .frame(width: 7, height: 7)
        .accessibilityLabel("Unread notifications")
    }
  }
}
