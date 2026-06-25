import SwiftUI

/// A centered, dismissable modal overlay for the command-palette dialogs (New / Open Workroom).
/// Replaces a `.sheet` so a click anywhere on the dimmed backdrop closes the dialog — a macOS sheet
/// is modal and ignores outside clicks. The card springs in on appear (mirrors `SetupOverlay`); its
/// opaque `panel` fill captures taps so clicks on the dialog itself never reach the backdrop.
struct DialogOverlay<Content: View>: View {
  let onDismiss: () -> Void
  @ViewBuilder var content: Content

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  private let theme = ThemeService.shared
  @State private var shown = false

  var body: some View {
    ZStack {
      // Dimmed backdrop — a tap anywhere on it dismisses (lighter in light mode, like SetupOverlay).
      Rectangle()
        .fill(Color.black.opacity(shown ? (colorScheme == .light ? 0.08 : 0.25) : 0))
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)

      content
        .background(theme.tokens.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(theme.tokens.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        .scaleEffect(shown ? 1 : 0.96)
        .opacity(shown ? 1 : 0)
    }
    .onAppear {
      guard !shown else { return }
      if reduceMotion {
        shown = true
      } else {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { shown = true }
      }
    }
  }
}
