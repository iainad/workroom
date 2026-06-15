import AppKit
import Defaults
import SwiftUI

extension Color {
  /// The focus indicator for a terminal pane's border — a solid colour that follows the app
  /// appearance rather than the system accent blue (issue #23 follow-up). A soft mid-graphite that
  /// stays gentle against both light and dark terminal backgrounds while reading as "the focused
  /// one" next to the faint hairline on unfocused panes. Resolved through a dynamic `NSColor` so it
  /// tracks `NSApp.appearance` (which `ThemePreference` drives), light or dark.
  static let focused = Color(
    nsColor: NSColor(name: "TerminalFocus") { appearance in
      appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 0.58, green: 0.59, blue: 0.63, alpha: 1)
        : NSColor(srgbRed: 0.50, green: 0.51, blue: 0.54, alpha: 1)
    })

  /// The scrim laid over unfocused terminal panes so the active one reads at a glance. It's the terminal's
  /// own background colour — `.textBackgroundColor`, the exact system colour `GhosttyApp` writes as the
  /// surface `background` — so the scrim is invisible *over the background* (same colour) and only washes
  /// the pane's text toward it. The background itself barely shifts in any mode; the text carries the
  /// focus signal. (A pure white/black scrim overshot dark mode, pushing the dark-grey BG toward black.)
  static let terminalDim = Color(nsColor: .textBackgroundColor)
}

/// The user's appearance choice. Persisted via `Defaults[.theme]`; `.system` (the default)
/// follows the OS appearance, while `.light`/`.dark` force a scheme. `PreferRawRepresentable`
/// stores the bare raw string (e.g. "system") — matching the old `@AppStorage` encoding, so
/// existing choices survive the upgrade — rather than Defaults' default Codable/JSON bridge.
enum ThemePreference: String, CaseIterable, Defaults.Serializable, Defaults.PreferRawRepresentable {
  case system
  case light
  case dark

  /// The AppKit appearance to apply app-wide, or nil to follow the system. We drive
  /// the appearance through NSApp rather than SwiftUI's `preferredColorScheme` because
  /// the latter fails to revert to the system appearance on macOS once a scheme has
  /// been forced. Setting `NSApp.appearance = nil` reliably tracks the system (and
  /// live-updates with it). The embedded terminals follow the appearance separately
  /// (see `TerminalSessions.applyThemeToAll`, which rebuilds the libghostty system-colors config).
  var nsAppearance: NSAppearance? {
    switch self {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }

  /// SF Symbol shown on the toggle button for the active mode.
  var symbol: String {
    switch self {
    case .system: return "circle.lefthalf.filled"
    case .light: return "sun.max"
    case .dark: return "moon"
    }
  }

  var label: String {
    switch self {
    case .system: return "System"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }

  /// The next mode when the toggle is clicked: System → Light → Dark → System.
  var next: ThemePreference {
    let all = Self.allCases
    return all[(all.firstIndex(of: self)! + 1) % all.count]
  }
}
