import Foundation

/// Shared, app-wide project data: the project list plus everything derived from it that is
/// identical across windows — root branch/bookmark labels, the VCS/CI status cache, GitHub-CLI
/// availability, and the in-flight project busy set. Extracted from `AppStore` (issue #70) so that
/// multiple per-window `AppStore`s can share one project list while each keeps its own selection,
/// terminals, splits, history, and run state.
///
/// This first step is **storage-only and behaviour-preserving**: `AppStore` proxies these
/// properties straight through to here and re-publishes the store's `objectWillChange`, so the
/// single shared `AppStore` still behaves exactly as before. The CLI/load logic stays on `AppStore`
/// for now (it mutates these via the proxies); per-window construction and the multi-window wiring
/// land in a follow-up.
@MainActor
final class ProjectStore: ObservableObject {
  /// The shared instance used in production (every window's `AppStore` points at it). Tests
  /// construct an isolated `AppStore()`, which gets its own fresh `ProjectStore`, so they never
  /// pollute this singleton or each other.
  static let shared = ProjectStore()

  /// The list of configured projects (from the CLI's `~/.config/workroom/config.json`). The one
  /// piece of state shared across all windows.
  @Published var projects: [Project] = []

  /// Per-project resolved root branch/bookmark labels, hydrated asynchronously after each load.
  @Published var rootRefs: [Project.ID: RootRef] = [:]

  /// Per-workroom (and per-root) VCS + CI status driving the ambient badges and the Changes panel
  /// (issue #24), keyed by `SidebarID`. Resolved app-side, best-effort/"last checked". Shared so two
  /// windows showing the same workroom report a consistent badge and don't double the probes.
  @Published var workroomStatuses: [SidebarID: WorkroomStatus] = [:]

  /// Whether the GitHub CLI is usable for the PR/CI probes (machine-global). Optimistic default so
  /// no warning flashes before the first check.
  @Published var githubCLIStatus: GitHubCLIStatus = .available

  /// When `githubCLIStatus` was last probed (its own short TTL, so we don't re-run `gh auth status`
  /// on every selection). Plain (non-`@Published`): it gates a re-probe, nothing renders from it.
  var ghStatusCheckedAt: Date?

  /// Project paths with an in-flight create/delete (for per-row progress + disabling).
  @Published var busyProjects: Set<String> = []
}
