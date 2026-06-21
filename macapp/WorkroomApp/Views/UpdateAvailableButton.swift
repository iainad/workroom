import SwiftUI

/// The accent "Update" pill in the leading title bar, shown when Sparkle has found a newer version in
/// the background (a gentle reminder — see `Updater`). Tapping it runs Sparkle's standard check, which
/// presents the already-found update's install prompt. Filled with the theme accent (like
/// `UnreadBadge`) so it reads as a call to action beside the plain icon buttons. Renders nothing when
/// no update is pending.
struct UpdateAvailableButton: View {
  @EnvironmentObject private var updater: Updater
  @State private var hovering = false
  private let theme = ThemeService.shared

  var body: some View {
    if let version = updater.availableVersionString {
      Button {
        updater.checkForUpdates()
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "arrow.down.circle.fill")
          Text("Update")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(theme.tokens.accentForeground)
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(theme.tokens.accent))
        .opacity(hovering ? 0.85 : 1)
        .contentShape(Capsule())
      }
      // Override the title bar's shared ToolbarIconButtonStyle — this is a filled pill, not an icon.
      .buttonStyle(.plain)
      .onHover { hovering = $0 }
      .animation(.easeOut(duration: 0.12), value: hovering)
      .help("Update to \(version) — click to install")
      .accessibilityLabel("Update available")
      .accessibilityIdentifier("toolbar.update")
    }
  }
}
