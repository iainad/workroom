import Foundation

/// Pure filter + keyboard-highlight logic for the New Workroom project picker (issue #81), factored
/// out of `NewWorkroomDialog` so it's unit-testable in isolation (mirrors `EdgeRevealReducer` /
/// `TabReorderMath` — the view owns the `query` / `highlight` `@State`, this just computes).
///
///   type ──► filtered(projects, query)    → the visible rows
///   ↑/↓  ──► move(highlight, by:, count:)  → clamped index, NO side effects (creation is click/⏎ only)
///   ⏎    ──► selection(filtered, highlight) → the project to create, or nil (empty / no-match guard)
enum ProjectPickerModel {
  /// Projects whose `displayName` contains `query` (case-insensitive, whitespace-trimmed). An empty
  /// query returns every project in the original order.
  static func filtered(_ projects: [Project], query: String) -> [Project] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return projects }
    return projects.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
  }

  /// Clamp `index` into a list of `count` items. Returns 0 for an empty list so callers always have a
  /// safe value; the `selection` guard still prevents acting on an empty list.
  static func clamped(_ index: Int, count: Int) -> Int {
    guard count > 0 else { return 0 }
    return min(max(index, 0), count - 1)
  }

  /// Move `highlight` by `delta`, clamped to `[0, count-1]`. No side effects — ↑/↓ only move the
  /// selection; a workroom is created on click/Return, never on a keystroke.
  static func move(highlight: Int, by delta: Int, count: Int) -> Int {
    clamped(highlight + delta, count: count)
  }

  /// The project Return/click should create: `filtered[highlight]`, or nil when the list is empty or
  /// the index is out of range — this is the guard that makes Return a no-op on an empty/no-match list.
  static func selection(filtered: [Project], highlight: Int) -> Project? {
    guard filtered.indices.contains(highlight) else { return nil }
    return filtered[highlight]
  }
}
