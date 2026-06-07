import Foundation

/// Whether the global show/hide shortcut (⌘§) is registered (issue #13). A setting because a
/// system-wide hotkey is intrusive — some users won't want Workroom claiming ⌘§. `AppDelegate`
/// reads this to register/unregister the hotkey live; the Settings `Toggle` writes it via
/// `@AppStorage`. Mirrors `CopyOnSelect`/`ConfirmOnQuit`.
enum GlobalHotkeyEnabled {
  static let storageKey = "globalHotkeyEnabled"

  /// Default ON: the key stays absent until the user first toggles it (the Settings `Toggle` is
  /// bound via `@AppStorage`, default `true`), so treat "unset" as enabled.
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
  }
}
