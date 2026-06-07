import Defaults

/// The single source of truth for every persisted preference: each `Key` owns both the
/// UserDefaults key string *and* the default value, so a default lives in exactly one place
/// (no more duplicating it across an enum getter and every `@Default`/`@AppStorage` site).
/// Read via `@Default(.foo)` in SwiftUI views and `Defaults[.foo]` everywhere else.
///
/// The key *strings* must stay byte-for-byte what they were under the old `@AppStorage`/enum-wrapper
/// storage so existing users' stored preferences carry over on upgrade. Sparkle's
/// `SUEnableAutomaticChecks` is deliberately absent — it's owned by `SPUUpdater`, not us.
extension Defaults.Keys {
  /// Appearance: System (follows the OS) / Light / Dark. Stored as the bare raw string via
  /// `ThemePreference: PreferRawRepresentable` (matching the old `@AppStorage` encoding).
  static let theme = Key<ThemePreference>("themePreference", default: .system)

  /// Copy a finished terminal selection to the pasteboard automatically (xterm/iTerm2 convention).
  static let copyOnSelect = Key<Bool>("copyOnSelect", default: true)

  /// Confirm before quitting (quitting tears down every terminal with no undo).
  static let confirmOnQuit = Key<Bool>("confirmOnQuit", default: true)

  /// Whether the global ⌘§ show/hide hotkey is registered (issue #13).
  static let globalHotkey = Key<Bool>("globalHotkeyEnabled", default: true)

  /// Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  static let filePathEditor = Key<String>("filePathEditorBundleID", default: "")

  /// Bundle id of the last editor picked from the toolbar "Open in…" menu; "" = none yet.
  static let lastEditor = Key<String>("openInEditorBundleID", default: "")

  /// Whether the right-hand notifications inspector is open.
  static let showNotifications = Key<Bool>("showNotificationsInspector", default: false)

  /// The persisted selected sidebar target as a `TerminalTarget.ID` string, or nil (issue #14).
  static let sidebarSelection = Key<String?>("sidebar.selectionTargetID", default: nil)

  /// Project paths the user has collapsed in the sidebar; absence of a path means expanded
  /// (the default). Persisted natively as a string array (issue #14).
  static let collapsedProjects = Key<Set<String>>("sidebar.collapsedProjects", default: [])
}
