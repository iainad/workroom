import Foundation

/// Persists the project-tree sidebar's state across launches (issue #14): which projects are
/// collapsed, and which row is selected. Column width is handled separately by AppKit split
/// autosave (see `SplitViewAutosave`). Follows the app's storage-key convention
/// (cf. `CopyOnSelect`, `ThemePreference`).
enum SidebarPersistence {
  /// JSON array of collapsed project paths — read/written by `ProjectSidebar`'s `@AppStorage`.
  static let collapsedProjectsKey = "sidebar.collapsedProjects"
  static let selectionKey = "sidebar.selectionTargetID"

  /// The persisted selected target as a `TerminalTarget.ID` string (or nil). Wraps the
  /// `UserDefaults` access so `AppStore` carries no raw key strings.
  static var selection: String? {
    get { UserDefaults.standard.string(forKey: selectionKey) }
    set {
      if let newValue {
        UserDefaults.standard.set(newValue, forKey: selectionKey)
      } else {
        UserDefaults.standard.removeObject(forKey: selectionKey)
      }
    }
  }
}

/// A JSON-backed `Set<String>` of collapsed project paths so `@AppStorage` can persist it while
/// callers keep using plain `contains`/`insert`/`remove`. Absence of a path means expanded (the
/// default), matching the in-memory semantics it replaces.
struct CollapsedProjects: RawRepresentable, Equatable {
  private(set) var paths: Set<String>

  init(_ paths: Set<String> = []) { self.paths = paths }

  init?(rawValue: String) {
    guard let data = rawValue.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String].self, from: data)
    else { return nil }
    paths = Set(decoded)
  }

  var rawValue: String {
    guard let data = try? JSONEncoder().encode(paths.sorted()),
      let string = String(data: data, encoding: .utf8)
    else { return "[]" }
    return string
  }

  func contains(_ path: String) -> Bool { paths.contains(path) }
  mutating func insert(_ path: String) { paths.insert(path) }
  mutating func remove(_ path: String) { paths.remove(path) }
}
