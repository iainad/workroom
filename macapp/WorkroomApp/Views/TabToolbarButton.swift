import SwiftUI

/// One icon-only toolbar action, styled to match the app's other small controls (the tab strip's
/// "+" new-terminal button, the remove-from-split ✕, the Changes-panel row hover toolbar): a small
/// glyph with a hover well, a tooltip, and an accessibility label + identifier (per the "tooltips on
/// all controls" convention). Carries its own `onHover` so the `.help` tooltip's tracking area is
/// reliably installed. Shared by the tab strip (issue #72) and the Changes panel (issue #93).
struct TabToolbarButton: View {
  let systemImage: String
  let help: String
  let accessibilityLabel: String
  let identifier: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(ThemeService.shared.tokens.hover.opacity(hovering ? 1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityIdentifier(identifier)
  }
}
