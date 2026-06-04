import AppKit
import SwiftTerm

/// "Copy on select": when the user finishes a mouse selection in a terminal, its text is
/// copied to the general pasteboard automatically (the xterm/iTerm2 convention). ⌘C is
/// unchanged; this is purely additive, and gated by a menu toggle (default on).
///
/// SwiftTerm's `mouseUp` is declared `public` (not `open`), so it can't be overridden from
/// this module, and `selectionChanged` fires on every `dragExtend` (churning the pasteboard
/// throughout a drag). Instead `AppDelegate` installs a `.leftMouseUp` `NSEvent` monitor and
/// calls `copyActiveSelection()` — once per mouse release, after the gesture has settled.
enum CopyOnSelect {
  static let storageKey = "copyOnSelect"

  /// Default ON: the key stays absent until the user first toggles it (the menu `Toggle`
  /// is bound via `@AppStorage`, default `true`), so treat "unset" as enabled.
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true
  }

  /// If enabled and the key window's focused view is a terminal with a non-empty
  /// selection, copy that selection to the pasteboard. Runs just after a left-mouse-up:
  /// every selection gesture (drag, double-click word, triple-click line) has updated the
  /// selection by then, and a plain click has already cleared it in the preceding
  /// `mouseDown` — so a deselecting click correctly copies nothing.
  @MainActor
  static func copyActiveSelection() {
    guard isEnabled,
      let terminal = focusedTerminal(in: NSApp.keyWindow),
      let text = terminal.getSelection(), !text.isEmpty
    else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  /// Walk up from the window's first responder to its hosting `LocalProcessTerminalView`,
  /// if any (a terminal is made first responder when its pane mounts).
  @MainActor
  private static func focusedTerminal(in window: NSWindow?) -> LocalProcessTerminalView? {
    var view = window?.firstResponder as? NSView
    while let current = view {
      if let terminal = current as? LocalProcessTerminalView { return terminal }
      view = current.superview
    }
    return nil
  }
}
