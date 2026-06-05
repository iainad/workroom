import Foundation

/// "Copy on select": when the user finishes a mouse selection in a terminal, its text is copied to
/// the general pasteboard automatically (the xterm/iTerm2 convention). ⌘C is unchanged; this is
/// purely additive, and gated by a menu toggle (default on).
///
/// The copy itself runs in `GhosttySurfaceView.mouseUp` (we own the NSView, so no `NSEvent` monitor
/// is needed); this type just owns the persisted toggle the menu binds to.
enum CopyOnSelect {
  static let storageKey = "copyOnSelect"

  /// Default ON: the key stays absent until the user first toggles it (the menu `Toggle` is bound
  /// via `@AppStorage`, default `true`), so treat "unset" as enabled.
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
  }
}
