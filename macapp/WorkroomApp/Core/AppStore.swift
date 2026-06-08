import Defaults
import Foundation
import SwiftUI

/// Identifies a selectable row in the project → (root | workroom) sidebar tree. Workroom
/// names can repeat across projects, and the root is per project, so both carry their
/// project path. The selected *terminal target* is one of these.
enum SidebarID: Hashable {
  case project(String)
  case root(project: String)
  case workroom(project: String, name: String)
}

/// A workroom queued for deletion, awaiting the user's confirmation. Held on the store so
/// both the sidebar's delete affordances and the Delete menu command (⌘⌫) raise the same
/// confirmation prompt.
struct PendingWorkroomDeletion {
  let workroom: Workroom
  let project: Project
}

/// App-wide state and actions. A single shared instance is used so the App, views,
/// and menu Commands all act on the same store. All CLI work is awaited (it runs off
/// the main thread inside WorkroomCLI), keeping the UI responsive.
@MainActor
final class AppStore: ObservableObject {
  static let shared = AppStore()

  @Published var projects: [Project] = []
  @Published var selectedProjectID: Project.ID?
  /// The selected terminal target — a `.root` or a `.workroom` (never `.project`), or nil
  /// when nothing is selected (the launch state). `.project` is not a target; clicking a
  /// project toggles its expansion instead. Persisted across launches (issue #14) via `didSet`
  /// and restored in `apply()`.
  @Published var selectedTargetID: SidebarID? {
    didSet {
      Defaults[.sidebarSelection] = Self.targetIDString(for: selectedTargetID)
      // Record the new location for back/forward (issue #26), unless we're replaying history.
      if !isNavigatingHistory { recordCurrentLocation() }
    }
  }
  /// Project paths the user has collapsed in the sidebar (issue #14). Held here as `@Published`
  /// rather than read via `@Default` in the view: a `@Default` change does not reliably re-evaluate
  /// the sidebar's `List` until some *other* state changes (e.g. the pointer moving over a row), so
  /// expand/collapse appeared to "stick" until you moved the mouse. `@Published` fires
  /// `objectWillChange` synchronously, so the tree updates on the click itself. Persisted via `didSet`.
  @Published var collapsedProjects: Set<String> = Defaults[.collapsedProjects] {
    didSet { Defaults[.collapsedProjects] = collapsedProjects }
  }
  /// Per-project resolved root branch/bookmark labels, hydrated asynchronously after each
  /// load (see `resolveBranches`). Absent ⇒ the root row shows a dim "root" until resolved.
  @Published var rootRefs: [Project.ID: RootRef] = [:]

  @Published var errorMessage: String?
  /// Title for the error alert. Nil falls back to the generic title; specific
  /// failures (e.g. teardown) set their own.
  @Published var errorTitle: String?
  @Published var isLoading = false
  /// Project paths with an in-flight create/delete (for per-row progress + disabling).
  @Published var busyProjects: Set<String> = []
  /// Set by the "Add Project" menu command to trigger the sidebar's file importer.
  @Published var requestAddProject = false
  /// A workroom awaiting delete confirmation; setting it raises the confirmation prompt.
  @Published var pendingDeletion: PendingWorkroomDeletion?
  /// Setup logs scoped per terminal target (a workroom's target id), rendered under that
  /// workroom's terminal. Kept until the user closes them (or the workroom is deleted) so
  /// the output stays available for review. Keyed on the target id (project-scoped) so
  /// same-named workrooms across projects don't share a log.
  @Published var logs: [TerminalTarget.ID: ScriptLogSession] = [:]

  let terminals = TerminalSessions()
  /// In-memory notification spine driving the badges + inspector (issue #10). Owned here,
  /// mirroring `terminals`; views observe it directly via `@EnvironmentObject`.
  let notifications = NotificationCenterStore()
  /// Posts native banners. Behind a protocol for testability; the real one wraps
  /// `UNUserNotificationCenter`.
  let systemNotifier: SystemNotifying = SystemNotifier()

  /// Browser-style back/forward history of visited `(target, tab)` locations (issue #26).
  /// `@Published` so toolbar/menu enablement (`canGoBack`/`canGoForward`) re-evaluates when it
  /// changes. Session-only — deliberately not persisted across launches. `private(set)` so unit
  /// tests can inspect it (read-only) while only the store mutates it.
  @Published private(set) var history = NavigationHistory()
  /// True while `navigateBack`/`navigateForward`/`applyLocation` are replaying, so the
  /// `selectedTargetID` didSet and the `terminals.onFocusChange` seam don't re-record the very
  /// location they're navigating to.
  private var isNavigatingHistory = false

  private let resolver = BranchResolver()
  /// The in-flight branch-resolution sweep; cancelled and replaced on each reload so a
  /// slow sweep never writes stale labels over a newer one.
  private var branchTask: Task<Void, Never>?
  /// When the project list was last loaded — used to throttle the on-focus refresh.
  private var lastLoadAt: Date = .distantPast
  /// The selection persisted from a previous launch (issue #14), applied once on the first
  /// successful load (see `apply`). Consumed there so a later refresh can't resurrect it.
  private var pendingRestoreSelection: TerminalTarget.ID?

  /// `internal` (not `private`) so unit tests can build a non-singleton store (`AppStore()`),
  /// inject `projects`, and drive the real recording/navigation paths. Production always uses the
  /// `shared` singleton; `init` does no CLI work (only `bootstrap()`/`load()` do).
  init() {
    pendingRestoreSelection = Defaults[.sidebarSelection]
    // Route each terminal's activity (OSC/bell) through the notification spine, gated on
    // focus, and raise a native banner only when the app is backgrounded.
    terminals.activityHandler = { [weak self] targetID, tabID, activity in
      self?.handleActivity(targetID: targetID, tabID: tabID, activity: activity)
    }
    // Record each focused-tab change for back/forward history (issue #26), unless we're replaying.
    terminals.onFocusChange = { [weak self] _, _ in
      guard let self, !self.isNavigatingHistory else { return }
      self.recordCurrentLocation()
    }
    // Prune dead entries when tabs are closed/reaped, so canGoBack/Forward stay honest (issue #26).
    terminals.onTabsRemoved = { [weak self] _, ids in
      self?.history.prune(removing: Set(ids))
    }
    // Mirror the aggregate unread count onto the Dock icon badge (issue #32). Owned here, not in a
    // view: see `NotificationCenterStore.onTotalChange` for why a view-driven badge misses
    // background notifications. `DockBadge` draws into the tile's `contentView` (not `badgeLabel`,
    // which a linked framework suppresses here). Captures no `self`, so there's no retain cycle.
    notifications.onTotalChange = { count in
      DockBadge.apply(count)
    }
  }

  var selectedProject: Project? {
    projects.first { $0.id == selectedProjectID }
  }

  /// The selected terminal target resolved against the current project list (nil if it no
  /// longer exists).
  var selectedTarget: TerminalTarget? { selectedTargetID.flatMap(target(for:)) }

  /// Resolve any `SidebarID` to its live `TerminalTarget` against the current project list (nil for
  /// `.project` or a since-removed target). Backs `selectedTarget` and the history `isLive` check.
  func target(for sid: SidebarID) -> TerminalTarget? {
    switch sid {
    case .root(let path):
      return projects.first { $0.id == path }?.rootTarget
    case .workroom(let path, let name):
      guard let project = projects.first(where: { $0.id == path }),
        let workroom = project.workrooms.first(where: { $0.id == name })
      else { return nil }
      return workroom.target(inProject: path)
    case .project:
      return nil
    }
  }

  /// The selected workroom, only when a workroom (not a root) is selected. Used by delete,
  /// the setup-log dock, and menu commands that are workroom-specific.
  var selectedWorkroom: Workroom? {
    guard case .workroom(let path, let name) = selectedTargetID,
      let project = projects.first(where: { $0.id == path })
    else { return nil }
    return project.workrooms.first { $0.id == name }
  }

  // MARK: Loading

  /// Initial launch: render config-only (instant, no VCS calls), then refresh warnings.
  /// Branch labels hydrate asynchronously off both passes (see `resolveBranches`).
  func bootstrap() async {
    if UITestFixture.isActive {
      loadFixture()
      return
    }
    await load(warnings: "none")
    await load(warnings: "fast")
  }

  func reload() async {
    await load(warnings: "fast")
  }

  /// Reload only if it's been a while since the last load. Driven by the app regaining
  /// focus, so alt-tabbing back doesn't fork a git/jj process per project every time.
  func reloadIfStale(minInterval: TimeInterval = 4) async {
    guard Date().timeIntervalSince(lastLoadAt) >= minInterval else { return }
    await reload()
  }

  private func load(warnings: String) async {
    // In UI-test fixture mode every load resolves to the same fake projects — never shell out to
    // the CLI (so an on-focus `reloadIfStale` can't replace the fixture with the real config).
    if UITestFixture.isActive {
      loadFixture()
      return
    }
    isLoading = true
    defer { isLoading = false }
    do {
      let response = try await WorkroomCLI.shared.list(warnings: warnings)
      apply(response.projects)
      lastLoadAt = Date()
      resolveBranches()
    } catch {
      present(error)
    }
  }

  /// Load the deterministic UI-test fixture (see `UITestFixture`): inject the fake projects and, on
  /// the first load, auto-select the fixture workroom so a terminal renders immediately — the tests
  /// then drive splits/closes without any fragile sidebar navigation. Branch resolution is skipped
  /// (the temp-dir paths aren't real repos), so no git/jj process is ever spawned. Idempotent: a
  /// later reload re-injects the same projects but preserves whatever the test has since selected.
  private func loadFixture() {
    let fixtures = UITestFixture.projects()
    projects = fixtures
    // The real persisted selection won't resolve against the fixture paths; don't try to restore it.
    pendingRestoreSelection = nil
    // Start every fixture project expanded so the sidebar tree is deterministic regardless of any
    // collapse state a prior UI-test run persisted to the shared defaults (real projects untouched).
    collapsedProjects.subtract(fixtures.map(\.id))
    if selectedProjectID == nil { selectedProjectID = fixtures.first?.id }
    if selectedTargetID == nil, let project = fixtures.first,
      let workroom = project.workrooms.first
    {
      selectedTargetID = .workroom(project: project.path, name: workroom.name)
    }
    lastLoadAt = Date()
  }

  private func apply(_ fresh: [Project]) {
    projects = fresh
    // First load after launch: restore last session's selection (issue #14) before it's
    // validated below. Resolved against the live projects, so a since-deleted target — or a
    // restore that loses the race to a user click — resolves to nil and falls through.
    if selectedTargetID == nil, let saved = pendingRestoreSelection {
      selectedTargetID = Self.sidebarID(forTargetID: saved, in: fresh)
    }
    pendingRestoreSelection = nil
    // Keep a project as the New-Workroom context; prefer the (possibly restored) selection's
    // project, else the first.
    if selectedProjectID == nil || !fresh.contains(where: { $0.id == selectedProjectID }) {
      selectedProjectID = Self.projectPath(of: selectedTargetID) ?? fresh.first?.id
    }
    // Keep the selected target only if it still exists. `validatedSelection` can only
    // return the existing selection or nil — it never fabricates one, so a load/refresh
    // can't auto-select a root or workroom the user didn't pick (D4).
    selectedTargetID = Self.validatedSelection(selectedTargetID, in: fresh)
    // Forget labels for projects that went away.
    let liveIDs = Set(fresh.map(\.id))
    rootRefs = rootRefs.filter { liveIDs.contains($0.key) }
  }

  /// Keeps the current selection if it still exists in `projects`, else nil. Never invents
  /// a selection — this is the guarantee behind D4 (a load/refresh must not auto-open a
  /// terminal). Pure + nonisolated so it's directly unit-testable (SelectionTests).
  nonisolated static func validatedSelection(_ current: SidebarID?, in projects: [Project])
    -> SidebarID?
  {
    guard let current else { return nil }
    return targetExists(current, in: projects) ? current : nil
  }

  nonisolated private static func targetExists(_ id: SidebarID, in projects: [Project]) -> Bool {
    switch id {
    case .root(let path):
      return projects.contains { $0.id == path }
    case .workroom(let path, let name):
      return projects.first { $0.id == path }?.workrooms.contains { $0.id == name } ?? false
    case .project:
      return false
    }
  }

  /// Hydrate each project's root branch/bookmark label off the main path. Per project,
  /// concurrent, cancellable: a slow/wedged repo only delays its own label, and a newer
  /// reload cancels this sweep so it can't write stale values. A resolution that comes
  /// back `.none` does not clobber a previously-resolved label (no flash to "root" on
  /// refresh). Project counts are small, so the group runs uncapped.
  private func resolveBranches() {
    branchTask?.cancel()
    let resolver = self.resolver
    let snapshot = projects.map { (id: $0.id, path: $0.path, vcs: $0.vcs) }
    branchTask = Task { [weak self] in
      await withTaskGroup(of: (String, RootRef).self) { group in
        for p in snapshot {
          group.addTask { (p.id, await resolver.resolve(path: p.path, vcs: p.vcs)) }
        }
        for await (id, ref) in group {
          guard !Task.isCancelled, let self else { break }
          if ref.kind == .none, self.rootRefs[id] != nil { continue }  // keep prior label
          self.rootRefs[id] = ref
        }
      }
    }
  }

  // MARK: Mutations

  func addProject(_ url: URL) async {
    do {
      try await WorkroomCLI.shared.addProject(url.path)
      await reload()
      // Select the freshly added project as context (no target — the root is one click away).
      if let match = projects.first(where: {
        $0.path == url.path || ($0.path as NSString).lastPathComponent == url.lastPathComponent
      }) {
        selectedProjectID = match.id
        selectedTargetID = nil
      }
    } catch {
      present(error)
    }
  }

  func createWorkroom(in project: Project) async {
    busyProjects.insert(project.path)
    defer { busyProjects.remove(project.path) }

    let session = ScriptLogSession(
      title: "Setting up new workroom in \(project.displayName)", phase: "setup")
    // Whether the project has a setup script; reported by the early "created" event.
    // A blocking session shows its log full-pane (no terminal) until the user dismisses.
    var hasSetup = false
    do {
      let created = try await WorkroomCLI.shared.create(
        project: project.path,
        onLog: { text in
          DispatchQueue.main.async { session.append(text) }
        },
        onReady: { name, _, setup in
          // The workroom now exists; mount it and (if a setup script will run) block its
          // terminal behind the streaming setup log so output appears live from the start.
          DispatchQueue.main.async {
            hasSetup = setup
            Task { @MainActor in
              await self.mountSetupLog(session, workroom: name, project: project, blocking: setup)
            }
          }
        }
      )
      session.finish()
      await reload()
      // Mount now if the early "created" event never arrived (older CLI).
      if session.targetID == nil {
        await mountSetupLog(session, workroom: created.name, project: project, blocking: hasSetup)
      }
      // A non-blocking run with no output leaves nothing to dock. A blocking session
      // stays up (even with no output) until the user dismisses it.
      if !session.blocking, session.lines.isEmpty, let id = session.targetID { logs[id] = nil }
    } catch {
      // Even on (partial) failure, reload so a "created but setup failed" workroom shows up.
      await reload()
      if let id = session.targetID {
        // The workroom exists; show the failure in its log. Keep it blocking (if a setup
        // script ran) so the failure replaces the terminal until the user dismisses it.
        session.blocking = hasSetup
        logs[id] = session
        selectedProjectID = project.id
        selectedTargetID = targetIDFromLogKey(id, project: project)
        session.finish(failure: errorText(error))
      } else {
        // Failed before the workroom existed — nothing to dock under.
        present(error)
      }
    }
  }

  /// Mounts a just-created workroom (selecting it) and attaches its setup log. When
  /// `blocking` is true the log replaces the terminal full-pane (a setup script is
  /// running); otherwise it docks beneath the terminal. Safe to call more than once.
  private func mountSetupLog(
    _ session: ScriptLogSession, workroom name: String, project: Project, blocking: Bool = false
  ) async {
    let id = TerminalTarget.workroomID(project: project.path, name: name)
    session.targetID = id
    session.blocking = blocking
    logs[id] = session
    await reload()
    selectedProjectID = project.id
    selectedTargetID = .workroom(project: project.path, name: name)
  }

  /// Removes the workroom from the sidebar immediately, then runs its teardown (script +
  /// workspace removal) in the background. On success the optimistic removal already
  /// matches reality; on failure we reload (so it reappears if it still exists) and
  /// surface the error.
  func deleteWorkroom(_ workroom: Workroom, in project: Project) {
    let targetID = TerminalTarget.workroomID(project: project.path, name: workroom.name)
    // Optimistic: drop it from the model now, reap its terminals/log, clear selection.
    removeWorkroomLocally(workroom, in: project)
    terminals.reap(targetID)
    logs[targetID] = nil
    // Drop the gone workroom's notifications and pull any banners it already delivered.
    systemNotifier.withdraw(tabIDs: notifications.removeForTarget(targetID))
    if selectedTargetID == .workroom(project: project.path, name: workroom.name) {
      selectedTargetID = nil
    }

    // Teardown continues in the background. We still collect its output so a failure
    // can be surfaced in an alert.
    Task {
      let log = ScriptLogSession(title: "Tearing down \(workroom.name)", phase: "teardown")
      do {
        try await WorkroomCLI.shared.delete(name: workroom.name, project: project.path) { text in
          DispatchQueue.main.async { log.append(text) }
        }
      } catch {
        await reload()
        presentTeardownFailure(workroom, error: error, log: log)
      }
    }
  }

  /// Drops a workroom from the in-memory project list so the sidebar updates instantly.
  private func removeWorkroomLocally(_ workroom: Workroom, in project: Project) {
    guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
    let p = projects[idx]
    projects[idx] = Project(
      path: p.path, vcs: p.vcs, workrooms: p.workrooms.filter { $0.id != workroom.id })
  }

  /// Maps a workroom log key ("wr|<project>|<name>") back to its selection id.
  private func targetIDFromLogKey(_ key: TerminalTarget.ID, project: Project) -> SidebarID? {
    let prefix = "wr|\(project.path)|"
    guard key.hasPrefix(prefix) else { return nil }
    return .workroom(project: project.path, name: String(key.dropFirst(prefix.count)))
  }

  /// Teardown failed (it ran in the background): pop an alert carrying the captured
  /// script output so the user can see why.
  private func presentTeardownFailure(_ workroom: Workroom, error: Error, log: ScriptLogSession) {
    let output = log.lines.map(\.text).joined(separator: "\n").trimmingCharacters(
      in: .whitespacesAndNewlines)
    errorTitle = "Teardown of ‘\(workroom.name)’ failed"
    errorMessage = output.isEmpty ? errorText(error) : output
  }

  private func errorText(_ error: Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }

  // MARK: Menu-command convenience

  /// Open a new terminal tab in the selected target — root or workroom (⌘T).
  func newTerminalInSelectedTarget() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.addTab(for: target)
  }

  /// Close the active terminal tab in the selected target (⌘W).
  func closeCurrentTerminalTab() {
    guard let target = selectedTarget,
      let active = terminals.activeTab(for: target)
    else { return }
    requestCloseTerminalTab(active.id, for: target)
  }

  /// Close a terminal tab, confirming first when `confirmOnCloseTerminal` is on (the default). The
  /// tab-strip ✕ and the ⌘W command both route through here, so the confirmation — and its "Don't
  /// ask me again" suppression — lives in one place. Closing a terminal kills its shell and anything
  /// running in it with no undo, so the alert mirrors the quit confirmation (same destruction class).
  func requestCloseTerminalTab(_ tabID: TerminalTab.ID, for target: TerminalTarget) {
    guard let tab = terminals.tabs(for: target).first(where: { $0.id == tabID }) else { return }
    // UI-test fixture mode closes without the modal so ⌘W / right-click Close are synchronous and
    // teardown never blocks on an alert (the launch-arg override can't reliably reach a Defaults Bool).
    guard Defaults[.confirmOnCloseTerminal], !UITestFixture.isActive else {
      terminals.closeTab(tabID, for: target)
      return
    }
    let alert = NSAlert()
    alert.messageText = "Close ‘\(tab.title)’?"
    alert.informativeText = "Closing this terminal stops any process running in it."
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Don't ask me again"
    let confirmed = alert.runModal() == .alertFirstButtonReturn
    // Ticking the box stops future confirmations whether they Close or Cancel — it means "stop
    // asking". Writes the same key the Settings toggle binds to.
    if alert.suppressionButton?.state == .on {
      Defaults[.confirmOnCloseTerminal] = false
    }
    if confirmed { terminals.closeTab(tabID, for: target) }
  }

  /// Focus the terminal tab at `index` (0-based, left-to-right across solo + split panes) in the
  /// selected target (⌘1…⌘9). No-ops if there's no tab at that position.
  func focusTerminalTab(at index: Int) {
    guard let target = selectedTarget else { return }
    let tabs = terminals.tabs(for: target)
    guard tabs.indices.contains(index) else { return }
    terminals.select(tabs[index].id, for: target)
  }

  /// Split the focused pane by opening a new terminal beside it: ⌘D to the right, ⇧⌘D below
  /// (issue #3). The new terminal inherits the focused pane's working directory.
  func splitFocusedRight() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.splitFocusedPane(for: target, orientation: .horizontal)
  }

  func splitFocusedDown() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.splitFocusedPane(for: target, edge: .bottom)
  }

  func splitFocusedLeft() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.splitFocusedPane(for: target, edge: .left)
  }

  func splitFocusedUp() {
    guard let target = selectedTarget, !target.isMissing else { return }
    terminals.splitFocusedPane(for: target, edge: .top)
  }

  /// Move keyboard focus to the adjacent pane in a split (⌥⌘arrows). Returns whether focus moved, so
  /// the key monitor passes the event through to the terminal when there's no pane that way.
  @discardableResult
  func focusPane(_ direction: PaneDirection) -> Bool {
    guard let target = selectedTarget else { return false }
    return terminals.focusAdjacentPane(direction, for: target)
  }

  // MARK: Navigation history (issue #26)

  /// Whether back/forward can move. Cursor-based (D2): liveness is validated when stepping, so a
  /// button can be enabled yet no-op in the rare case where every entry that way is dead.
  var canGoBack: Bool { history.canGoBack }
  var canGoForward: Bool { history.canGoForward }

  /// Record the on-screen location (selected target + its focused tab) into history. No-op while
  /// replaying (guarded at the call sites) and when there's no focused terminal yet — so a switch to
  /// a never-visited target records nothing until its first terminal exists, and the later
  /// `addTab`→`onFocusChange` records the real first entry (no `(target, nil)` ghost).
  private func recordCurrentLocation() {
    guard let sid = selectedTargetID, let target = selectedTarget, !target.isMissing,
      let tab = terminals.focusedTab(for: target)
    else { return }
    history.record(NavLocation(target: sid, tab: tab.id))
  }

  /// Go back one step, skipping entries whose target/tab no longer exist (D2). No-op when there's no
  /// live earlier location.
  func navigateBack() {
    if let loc = history.step(-1, isLive: isLive) {
      applyLocation(target: loc.target, tab: loc.tab, recordHistory: false)
    }
  }

  /// Go forward one step (mirrors `navigateBack`).
  func navigateForward() {
    if let loc = history.step(+1, isLive: isLive) {
      applyLocation(target: loc.target, tab: loc.tab, recordHistory: false)
    }
  }

  /// The single primitive for "go to (target, tab)": used by back/forward replay and by
  /// `openTerminal` (notification / ⇧⌘N). Sets the selection + focuses the tab with history recording
  /// suppressed (the `didSet`/`onFocusChange` seams no-op via `isNavigatingHistory`), then records
  /// exactly one entry when `recordHistory` is true — so a jump never leaves a phantom intermediate
  /// entry. `tab` is optional (an old notification may carry none / a stale id); it resolves to the
  /// requested tab when it still exists, else the target's current focused tab.
  private func applyLocation(target sid: SidebarID, tab tabID: TerminalTab.ID?, recordHistory: Bool)
  {
    isNavigatingHistory = true
    defer { isNavigatingHistory = false }
    selectedProjectID = Self.projectPath(of: sid)
    selectedTargetID = sid
    guard let target = selectedTarget, !target.isMissing else { return }
    let resolved =
      tabID.flatMap { id in terminals.tabs(for: target).contains { $0.id == id } ? id : nil }
      ?? terminals.focusedTab(for: target)?.id
    guard let resolved else { return }
    terminals.focus(resolved, for: target)
    if recordHistory { history.record(NavLocation(target: sid, tab: resolved)) }
  }

  /// Whether a recorded location is still reachable: its target resolves to a live, non-missing
  /// target and the recorded tab still exists there. Skips dead entries (closed tab / deleted
  /// workroom) on back/forward.
  private func isLive(_ loc: NavLocation) -> Bool {
    guard let target = target(for: loc.target), !target.isMissing else { return false }
    return terminals.tabs(for: target).contains { $0.id == loc.tab }
  }

  // MARK: Notifications

  /// Record a terminal's activity, then post a native banner only if the app is backgrounded
  /// (foreground gets in-app badges only — decision 1.2). `record` drops the event entirely
  /// when the user is already looking at that terminal.
  private func handleActivity(
    targetID: TerminalTarget.ID, tabID: TerminalTab.ID, activity: TerminalActivity
  ) {
    // "Seen" = on screen (the focused solo tab or any pane of the visible split) — those are
    // suppressed (D3). A visible pane that isn't the cursor pane gets a border flash instead of a
    // badge, so split-mates still signal activity without nagging.
    let seen = isFocused(targetID: targetID, tabID: tabID)
    if seen, let target = selectedTarget, target.id == targetID,
      terminals.focusedTab(for: target)?.id != tabID
    {
      terminals.pulsePaneActivity(tabID)
    }
    guard
      let note = notifications.record(
        targetID: targetID, tabID: tabID, source: notificationSource(forTargetID: targetID),
        activity: activity, focused: seen)
    else { return }
    guard NotificationGate.shouldPostBanner(recorded: true, appActive: NSApp.isActive) else {
      return
    }
    Task { @MainActor in
      if await systemNotifier.ensureAuthorized() {
        systemNotifier.post(note)
      }
    }
  }

  /// Whether the user is currently looking at this terminal: the app is frontmost, one of its windows
  /// is key, and the tab is **visible** in the selected target — the focused solo tab, or any pane of
  /// the on-screen split (issue #3, decision D3). A notification's job is to surface the unseen, and an
  /// on-screen pane is seen — so visible panes are suppressed; a visible non-focused pane gets a
  /// per-pane border flash instead (see `handleActivity`). Window-aware so a sheet, a background
  /// window, or a non-frontmost app don't count as focused (issue #10, tension 2).
  func isFocused(targetID: TerminalTarget.ID, tabID: TerminalTab.ID) -> Bool {
    guard NSApp.isActive, NSApp.keyWindow != nil else { return false }
    guard let target = selectedTarget, target.id == targetID else { return false }
    return terminals.visibleTabIDs(for: target).contains(tabID)
  }

  /// Bring the app forward and select the terminal a notification came from, marking it read.
  /// Reused by both the native-banner click (AppDelegate) and the in-app panel tap. No-ops (and
  /// withdraws any stale banner) when the target/tab no longer exists.
  func openTerminal(targetID: TerminalTarget.ID, tabID: TerminalTab.ID?, notifID: UUID? = nil) {
    NSApp.activate(ignoringOtherApps: true)
    guard let sid = Self.sidebarID(forTargetID: targetID, in: projects) else {
      if let tabID { systemNotifier.withdraw(tabIDs: [tabID]) }
      return
    }
    // Jump to (target, tab) through the shared primitive: it selects the target, re-activates the
    // tab only if it still exists (it may have been closed/reaped since the banner was posted), and
    // records exactly one history entry — no phantom intermediate (issue #26).
    applyLocation(target: sid, tab: tabID, recordHistory: true)
    if let notifID {
      notifications.dismiss(notifID: notifID)
    } else if let tabID {
      notifications.dismiss(tab: tabID)
    }
  }

  /// Jump to the oldest pending notification's terminal and dismiss it (reusing the banner/panel
  /// `openTerminal` path). Since opening dismisses, repeated calls walk the backlog oldest→newest —
  /// the bottom of the inspector panel upward. No-op when there are none.
  func openOldestNotification() {
    guard let oldest = notifications.items.first else { return }
    openTerminal(targetID: oldest.targetID, tabID: oldest.tabID, notifID: oldest.id)
  }

  /// On app refocus, dismiss the notifications for the now-visible terminal (the selected target's
  /// active tab) — you're looking at it. Called from `RootView`'s `didBecomeActive` hook.
  func dismissFocusedTerminalNotifications() {
    guard let target = selectedTarget, let active = terminals.activeTab(for: target) else { return }
    notifications.dismiss(tab: active.id)
  }

  /// Human-readable origin for a notification: the project name, plus the workroom for a
  /// workroom terminal (e.g. "platform" for a root, "platform / fix-auth" for a workroom).
  /// Resolved against the live projects (no string parsing of the id).
  private func notificationSource(forTargetID id: TerminalTarget.ID) -> String {
    for p in projects {
      if TerminalTarget.rootID(project: p.path) == id { return p.displayName }
      for w in p.workrooms where TerminalTarget.workroomID(project: p.path, name: w.name) == id {
        return "\(p.displayName) / \(w.name)"
      }
    }
    return ""
  }

  /// Reverse a `TerminalTarget.ID` to its `SidebarID` by matching the live projects (robust to
  /// the `wr|project|name` delimiter — no string parsing). Pure + nonisolated so it's directly
  /// unit-testable, mirroring `validatedSelection`.
  nonisolated static func sidebarID(forTargetID id: TerminalTarget.ID, in projects: [Project])
    -> SidebarID?
  {
    for p in projects {
      if TerminalTarget.rootID(project: p.path) == id { return .root(project: p.path) }
      for w in p.workrooms where TerminalTarget.workroomID(project: p.path, name: w.name) == id {
        return .workroom(project: p.path, name: w.name)
      }
    }
    return nil
  }

  /// Encode a selectable target to its `TerminalTarget.ID` string for persistence (issue #14) —
  /// the inverse of `sidebarID(forTargetID:in:)`. `.project`/nil aren't selectable targets.
  nonisolated static func targetIDString(for id: SidebarID?) -> String? {
    switch id {
    case .root(let path): return TerminalTarget.rootID(project: path)
    case .workroom(let path, let name): return TerminalTarget.workroomID(project: path, name: name)
    case .project, .none: return nil
    }
  }

  /// The owning project path of any sidebar id (used to keep the New-Workroom context on the
  /// restored selection's project).
  nonisolated static func projectPath(of id: SidebarID?) -> String? {
    switch id {
    case .root(let path), .workroom(let path, _), .project(let path): return path
    case .none: return nil
    }
  }

  // MARK: Errors

  private func present(_ error: Error) {
    errorTitle = nil  // generic title
    errorMessage = errorText(error)
  }
}

/// The live log for one create/delete run. Lines stream in from the CLI's NDJSON
/// stderr (see WorkroomCLI). A plain ObservableObject — all mutations happen on the
/// main thread (the store hops there before appending), so SwiftUI sees them safely.
final class ScriptLogSession: ObservableObject, Identifiable {
  let id = UUID()
  let title: String
  let phase: String
  /// The terminal target id this log is docked under, once the CLI reports the workroom
  /// exists. nil while the workroom is still being created.
  var targetID: TerminalTarget.ID?
  /// When true, this session blocks its workroom's terminal: the detail pane shows the
  /// setup log full-pane (no terminal) until the user dismisses it. Set once, before the
  /// session is inserted into the observed `logs` dict, so it must NOT be @Published —
  /// flipping it after mount would create then tear down a terminal (mirrors `targetID`).
  var blocking = false
  @Published private(set) var lines: [LogLine] = []
  @Published private(set) var isFinished = false
  @Published private(set) var failureMessage: String?

  init(title: String, phase: String) {
    self.title = title
    self.phase = phase
  }

  func append(_ text: String) {
    lines.append(LogLine(index: lines.count, text: Self.stripANSI(text)))
  }

  func finish(failure: String? = nil) {
    failureMessage = failure
    isFinished = true
  }

  struct LogLine: Identifiable {
    let index: Int
    let text: String
    var id: Int { index }
  }

  /// Strips ANSI SGR/escape sequences (e.g. color codes a setup script emits) so the
  /// log renders as clean text.
  private static let ansiRegex = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*[A-Za-z]")
  static func stripANSI(_ s: String) -> String {
    guard let re = ansiRegex else { return s }
    return re.stringByReplacingMatches(
      in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
  }
}
