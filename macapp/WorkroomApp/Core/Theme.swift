import AppKit

/// The user's appearance choice. Persisted in UserDefaults via @AppStorage; `.system`
/// (the default) follows the OS appearance, while `.light`/`.dark` force a scheme.
enum ThemePreference: String, CaseIterable {
  case system
  case light
  case dark

  /// The AppKit appearance to apply app-wide, or nil to follow the system. We drive
  /// the appearance through NSApp rather than SwiftUI's `preferredColorScheme` because
  /// the latter fails to revert to the system appearance on macOS once a scheme has
  /// been forced. Setting `NSApp.appearance = nil` reliably tracks the system (and
  /// live-updates with it). The embedded terminals follow the appearance separately
  /// (see `ThemedTerminalView` / `TerminalSessions.applyThemeToAll`).
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

/// Shared UserDefaults key so the toggle (in the sidebar) and the scheme application
/// (at the root) read and write the same stored value.
extension ThemePreference {
  static let storageKey = "themePreference"
}
