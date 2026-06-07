import AppKit
import Defaults

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
