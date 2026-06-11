import Defaults
import XCTest

@testable import Workroom

/// Store-level tests for the per-project "Run command" feature (issue #7). They drive a real,
/// non-singleton `AppStore` with the terminal factory seam overridden (so no live PTY) and capture
/// the command string handed to `makeView` to assert the shell wrap. Run-state lives on the store
/// (OV-A), so it's all inspectable here; the libghostty `command`/child-exit behaviour itself is
/// verified live (T1), and the toolbar/menu/sidebar wiring via XCUITest (T13).
@MainActor
final class RunCommandTests: XCTestCase {
  private var captured: [String?] = []

  override func setUp() {
    super.setUp()
    captured = []
    Defaults[.runCommands] = [:]
  }

  override func tearDown() {
    Defaults[.runCommands] = [:]
    super.tearDown()
  }

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { [weak self] _, cwd, command in
      self?.captured.append(command)
      return GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
    }
    store.projects = projects
    return store
  }

  private func project(_ path: String, workrooms: [String]) -> Project {
    Project(
      path: path, vcs: "git",
      workrooms: workrooms.map {
        Workroom(name: $0, path: "\(path)/\($0)", vcsName: "workroom/\($0)", warnings: [])
      })
  }

  private func target(_ store: AppStore, _ project: String, _ name: String) -> TerminalTarget {
    store.target(for: .workroom(project: project, name: name))!
  }

  /// The run terminal's surface view (so a test can simulate child-exit via `handleChildExited`).
  private func runView(_ store: AppStore, _ target: TerminalTarget) -> GhosttySurfaceView? {
    store.runTabID(for: target.id).flatMap { store.terminals.tab($0, for: target)?.view }
  }

  // MARK: Storage

  func testRunConfigRoundTripAndRemoval() {
    let store = makeStore([])
    let config = RunConfig(command: "npm run dev", autoRun: true)
    store.setRunConfig(config, forProject: "/a")
    XCTAssertEqual(store.runConfig(forProject: "/a"), config)
    XCTAssertTrue(store.hasRunCommand(forProject: "/a"))

    // A blank command with auto-run off removes the entry (no dead keys).
    store.setRunConfig(.empty, forProject: "/a")
    XCTAssertEqual(store.runConfig(forProject: "/a"), .empty)
    XCTAssertNil(Defaults[.runCommands]["/a"])
    XCTAssertFalse(store.hasRunCommand(forProject: "/a"))
  }

  func testSetRunConfigTrimsCommand() {
    let store = makeStore([])
    store.setRunConfig(RunConfig(command: "  bin/dev  ", autoRun: false), forProject: "/a")
    XCTAssertEqual(store.runConfig(forProject: "/a").command, "bin/dev")
  }

  // MARK: Start

  func testStartRunCommandSpawnsTracksAndWraps() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.startRunCommand(for: t)

    XCTAssertNotNil(store.runTabID(for: t.id))
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    // Wrapped in an interactive login shell so it gets the user's environment (A3). Assert `-lic`
    // specifically — `-l` alone would also match the degraded `/bin/sh -lc` fallback (review #15).
    let cmd = try! XCTUnwrap(captured.last as? String)
    XCTAssertTrue(cmd.contains("'echo hi'"), "command not single-quoted: \(cmd)")
    XCTAssertTrue(cmd.contains("-lic"), "not an interactive login shell: \(cmd)")
  }

  func testStartIsNoOpWithoutCommand() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    XCTAssertNil(store.runTabID(for: t.id))
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  func testStartSingleQuoteEscaping() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo 'x'", autoRun: false), forProject: "/a")
    store.startRunCommand(for: target(store, "/a", "main"))
    let cmd = try! XCTUnwrap(captured.last as? String)
    XCTAssertTrue(cmd.contains("'\\''"), "single quotes not POSIX-escaped: \(cmd)")
  }

  func testStartDoesNotDuplicateRunTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let first = store.runTabID(for: t.id)
    store.startRunCommand(for: t)  // already exists → focus, no second spawn
    XCTAssertEqual(store.runTabID(for: t.id), first)
    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 1)
  }

  // MARK: Child-exit / stop / restart

  func testChildExitFlipsToStoppedButKeepsPane() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tabID = store.runTabID(for: t.id)

    runView(store, t)?.handleChildExited(exitCode: 0)

    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(store.runTabID(for: t.id), tabID, "pane should stay open after exit")
  }

  func testRunOrFocusReRunsAStoppedTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.startRunCommand(for: t)
    let first = store.runTabID(for: t.id)
    runView(store, t)?.handleChildExited(exitCode: 0)  // now stopped-but-open
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))

    store.runOrFocusRunCommand()  // ensure-running: stopped → re-run (OV-B)
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertNotEqual(store.runTabID(for: t.id), first, "re-run should spawn a fresh tab")
  }

  func testClosingRunTabClearsState() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tabID = try! XCTUnwrap(store.runTabID(for: t.id))

    store.terminals.closeTab(tabID, for: t)

    XCTAssertNil(store.runTabID(for: t.id))
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  func testGracefulRestartReplacesTabAfterExit() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let first = try! XCTUnwrap(store.runTabID(for: t.id))

    store.restartRunCommand(for: t)  // running → Ctrl-C, await exit (still running until exit)
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(store.runTabID(for: t.id), first, "old tab persists until it actually exits")

    runView(store, t)?.handleChildExited(exitCode: 0)  // exit → (deferred) close + respawn

    // markRunExited defers the close+respawn off libghostty's child-exit callback stack (re-entrancy
    // safety). Pump the main queue (FIFO) so the deferred block runs before we assert.
    let pumped = expectation(description: "deferred respawn")
    DispatchQueue.main.async { pumped.fulfill() }
    wait(for: [pumped], timeout: 1)

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertNotEqual(store.runTabID(for: t.id), first, "restart should spawn a fresh tab")
  }

  func testArmedAutoRunStartsOnInitialTerminalMount() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: true), forProject: "/a")
    let t = target(store, "/a", "main")

    store.armAutoRun(forWorkroom: t.id)
    store.ensureInitialTerminal(for: t)  // the terminal pane mounting → run command becomes tab #1

    XCTAssertNotNil(store.runTabID(for: t.id), "armed auto-run should start the command on mount")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 1, "no orphan default tab")
  }

  func testInitialTerminalIsDefaultShellWhenNotArmed() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.ensureInitialTerminal(for: t)  // not armed → a plain terminal, no auto-run

    XCTAssertNil(store.runTabID(for: t.id))
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 1)
  }

  func testToggleStartsWhenNotRunning() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))

    store.toggleRunCommand(for: t)  // sidebar run button: not running → start

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertNotNil(store.runTabID(for: t.id))
  }

  func testReapClearsRunState() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))

    store.terminals.reap(t.id)

    XCTAssertNil(store.runTabID(for: t.id))
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  /// Regression: a graceful restart puts the target in `.restarting`; if the run tab is closed before
  /// the child exits (so `markRunExited` never consumes it), closing must clear that state. Otherwise
  /// the next run's natural exit is misread as a pending restart and respawns unexpectedly (review #1).
  func testClosingTabMidRestartDoesNotRespawnTheNextRun() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.startRunCommand(for: t)
    store.restartRunCommand(for: t)  // running → Ctrl-C, arm pendingRestart, await exit
    let firstTab = try! XCTUnwrap(store.runTabID(for: t.id))

    store.terminals.closeTab(firstTab, for: t)  // user ⌘W before the child exits
    XCTAssertNil(store.runTabID(for: t.id))

    // A fresh run; its natural exit must NOT trigger a respawn (no stale pendingRestart).
    store.startRunCommand(for: t)
    let freshTab = try! XCTUnwrap(store.runTabID(for: t.id))
    runView(store, t)?.handleChildExited(exitCode: 0)

    // Pump the main queue so any (buggy) deferred respawn would have run before we assert.
    let pumped = expectation(description: "no respawn")
    DispatchQueue.main.async { pumped.fulfill() }
    wait(for: [pumped], timeout: 1)

    XCTAssertFalse(store.isRunCommandRunning(for: t.id), "exited run stays stopped")
    XCTAssertEqual(store.runTabID(for: t.id), freshTab, "must not respawn a new tab")
  }

  /// Stop is graceful first, hard kill second (OV-D): the 1st press keeps the pane (Ctrl-C in flight),
  /// the 2nd closes the tab for a process that ignores SIGINT.
  func testStopEscalatesToHardKillOnSecondPress() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tab = try! XCTUnwrap(store.runTabID(for: t.id))

    store.stopRunCommand(for: t)  // 1st press → Ctrl-C, pane stays
    XCTAssertEqual(store.runTabID(for: t.id), tab, "1st Stop keeps the pane")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id), "still running until the child exits")

    store.stopRunCommand(for: t)  // 2nd press → hard kill
    XCTAssertNil(store.runTabID(for: t.id), "2nd Stop closes the tab")
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  /// Regression (#3): a Stop pressed right after a Restart must stay graceful, not hard-kill on the
  /// first press. Restart's Ctrl-C is already in flight, so the first Stop just drops the respawn
  /// intent (pane stays); only a second Stop escalates.
  func testStopAfterRestartIsGracefulNotImmediateHardKill() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tab = try! XCTUnwrap(store.runTabID(for: t.id))

    store.restartRunCommand(for: t)  // running → restarting (Ctrl-C, await exit)
    store.stopRunCommand(for: t)  // 1st Stop after Restart: must NOT close the tab
    XCTAssertEqual(store.runTabID(for: t.id), tab, "1st Stop after Restart stays graceful")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))

    store.stopRunCommand(for: t)  // now escalates
    XCTAssertNil(store.runTabID(for: t.id), "2nd Stop hard-kills")
  }

  /// Run controls show only for a present target whose project has a command — not for a missing
  /// directory (where startRunCommand silently no-ops), and not without a command (review #9/#14).
  func testCanRunCommandGate() {
    let store = makeStore([])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let present = TerminalTarget(id: "x", title: "main", path: "/a/main", isMissing: false)
    let missing = TerminalTarget(id: "y", title: "gone", path: "/a/gone", isMissing: true)

    XCTAssertTrue(store.canRunCommand(for: present, inProject: "/a"))
    XCTAssertFalse(store.canRunCommand(for: missing, inProject: "/a"), "missing → no run controls")
    XCTAssertFalse(
      store.canRunCommand(for: present, inProject: "/b"), "no command → no run controls")
  }
}
