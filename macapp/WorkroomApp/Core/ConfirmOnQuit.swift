import Foundation

/// "Confirm before quitting": quitting tears down every terminal (and anything running in them) at
/// once, with no undo, so by default a confirmation alert guards it (see
/// `AppDelegate.applicationShouldTerminate`). This type owns the persisted toggle the Workroom menu
/// and Settings bind to; mirrors `CopyOnSelect`.
enum ConfirmOnQuit {
  static let storageKey = "confirmOnQuit"

  /// Default ON: the key stays absent until the user first toggles it (both `Toggle`s are bound via
  /// `@AppStorage`, default `true`), so treat "unset" as enabled. Settable so the quit dialog's
  /// "Don't ask me again" checkbox can turn it off — the bound `@AppStorage` toggles observe the
  /// write and update.
  static var isEnabled: Bool {
    get { UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: storageKey) }
  }
}
