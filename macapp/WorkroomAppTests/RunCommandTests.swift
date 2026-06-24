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
    store.runTabID(for: target.id).flatMap { store.terminals.tab($0, for: target)?.surface }
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
    XCTAssertTrue(cmd.contains("echo hi"), "command not present: \(cmd)")
    XCTAssertTrue(cmd.contains("-lic"), "not an interactive login shell: \(cmd)")
    // Captures the run command's pid so Stop/Restart can resolve its process group (getpgid) and
    // SIGINT it like a typed Ctrl-C (issue #7): the wrapper writes $$ to a per-run file, then exec's
    // a child shell to run the command (so compound commands work + everything stays in the group).
    XCTAssertTrue(cmd.contains("echo $$ >"), "wrapper doesn't capture the pid: \(cmd)")
    XCTAssertTrue(cmd.contains("workroom-run-"), "no per-run pid file path: \(cmd)")
    // Records the command's real exit code to a file via an EXIT trap (issue #79) — libghostty's
    // child-exit code is unreliable, so the failure signal reads this instead.
    XCTAssertTrue(cmd.contains("trap "), "wrapper doesn't install an exit-code trap: \(cmd)")
    XCTAssertTrue(cmd.contains("EXIT"), "exit-code capture not on the EXIT trap: \(cmd)")
    XCTAssertTrue(cmd.contains(".exit"), "no per-run exit-code file path: \(cmd)")
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
    store.startRunCommand(for: t)  // already exists → no-op (issue #67: no re-focus)
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

  /// Put the run tab in a split (run tab + one sibling), then restart it. The fresh run tab must take
  /// the old one's slot — the split stays intact with the new tab in it — rather than collapsing the
  /// split and reappearing as a solo pane outside it (issue #40).
  func testGracefulRestartKeepsRunTabInSplit() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    let sibling = store.terminals.addTab(for: t).id  // a second pane to split against
    // Split: [sibling, run].
    store.terminals.moveTabIntoSplit(runID, ontoEdge: .right, of: sibling, for: t)
    XCTAssertEqual(store.terminals.split(for: t)?.tabIDs, [sibling, runID])

    store.restartRunCommand(for: t)  // running → Ctrl-C, await exit
    runView(store, t)?.handleChildExited(exitCode: 0)  // exit → (deferred) close + respawn in place

    let pumped = expectation(description: "deferred respawn")
    DispatchQueue.main.async { pumped.fulfill() }
    wait(for: [pumped], timeout: 1)

    let newRun = try! XCTUnwrap(store.runTabID(for: t.id))
    XCTAssertNotEqual(newRun, runID, "restart spawns a fresh tab")
    let split = try! XCTUnwrap(store.terminals.split(for: t), "split must survive the restart")
    XCTAssertEqual(split.tabIDs, [sibling, newRun], "new run tab takes the old one's slot")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
  }

  /// The stopped-but-open re-run path (⌘R on an exited run tab) must likewise keep the tab in its split
  /// instead of pulling it out (issue #40). This path is synchronous (no graceful Ctrl-C/await).
  func testStoppedReRunKeepsRunTabInSplit() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")

    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    let sibling = store.terminals.addTab(for: t).id
    store.terminals.moveTabIntoSplit(runID, ontoEdge: .left, of: sibling, for: t)  // [run, sibling]
    runView(store, t)?.handleChildExited(exitCode: 0)  // run tab now stopped-but-open
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))

    store.runOrFocusRunCommand()  // stopped → re-run in place

    let newRun = try! XCTUnwrap(store.runTabID(for: t.id))
    XCTAssertNotEqual(newRun, runID, "re-run spawns a fresh tab")
    let split = try! XCTUnwrap(store.terminals.split(for: t), "split must survive the re-run")
    XCTAssertEqual(split.tabIDs, [newRun, sibling], "new run tab takes the old one's slot")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
  }

  func testArmedAutoRunBackgroundsRunAndOpensShell() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: true), forProject: "/a")
    let t = target(store, "/a", "main")

    // Armed auto-run + the always-on "open a terminal in new workrooms": the run starts as a
    // BACKGROUNDED tab #1 (running, not focused) and a plain shell opens as the focused tab #2 the user
    // lands on (issue #67 / Arch #5).
    store.armAutoRun(forWorkroom: t.id)
    store.ensureInitialTerminal(for: t)  // the terminal pane mounting

    XCTAssertNotNil(store.runTabID(for: t.id), "armed auto-run should start the command on mount")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id), "run still starts, just in the background")
    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 2, "run tab + shell tab")
    let active = store.terminals.activeTab(for: t)?.id
    XCTAssertNotNil(active)
    XCTAssertNotEqual(
      active, store.runTabID(for: t.id), "the shell is focused, the run is backgrounded")
  }

  func testInitialTerminalOpensShellWhenNotArmed() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    // Not armed (auto-run off) → mounting a pane with no terminals always opens a single plain shell,
    // no run tab: a newly created workroom and an existing workroom/root selected with none open both
    // land the user in a terminal. A configured-but-not-auto run command must not start here.
    store.ensureInitialTerminal(for: t)

    XCTAssertNil(store.runTabID(for: t.id), "no auto-run → no run tab")
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 1, "one shell terminal opened")
  }

  func testInitialTerminalIdempotentAcrossRemounts() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")

    store.ensureInitialTerminal(for: t)
    store.ensureInitialTerminal(for: t)  // a re-mount (navigate away and back) must not re-open

    XCTAssertEqual(store.terminals.tabCount(forTargetID: t.id), 1, "no duplicate shell on re-mount")
  }

  func testInitialTerminalLeavesExistingTerminalsAlone() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    let t = target(store, "/a", "main")

    // A target that already has a terminal open gets no extra one — "open one if there are none open".
    store.terminals.addTab(for: t)
    store.ensureInitialTerminal(for: t)

    XCTAssertEqual(
      store.terminals.tabCount(forTargetID: t.id), 1, "existing terminal → no extra tab")
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

  /// Stop is graceful (issue #7, Option B): 1st press Ctrl-C keeps the pane (shutdown in flight); 2nd
  /// press closes the run tab — waiting for a live process to exit first (see the live-wait tests
  /// below). The test surface has no real PTY (`hasLiveProcess` false), so here the close is immediate.
  func testStopEscalatesToCloseOnSecondPress() {
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

  // MARK: Graceful teardown (issue #7, Option B) — a live run command (e.g. Puma) gets a Ctrl-C and
  // a wait for it to actually exit before its surface is freed, so it isn't orphaned by the bare PTY
  // hangup (SIGHUP, which Puma ignores) → "A server is already running" on the next start. Tests run
  // without a real PTY, so `liveProcessOverrideForTesting` stands in for a live child process.

  /// A small async settle so a scheduled `pollUntilExited` tick (asyncAfter 0.1s) runs before asserting.
  private func settle(_ seconds: TimeInterval = 0.25) {
    let done = expectation(description: "settle")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
    wait(for: [done], timeout: seconds + 1)
  }

  func testSecondStopWaitsForLiveProcessThenCloses() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tab = try! XCTUnwrap(store.runTabID(for: t.id))
    let view = try! XCTUnwrap(runView(store, t))
    view.liveProcessOverrideForTesting = true  // a dev server still running

    store.stopRunCommand(for: t)  // 1st press → Ctrl-C
    store.stopRunCommand(for: t)  // 2nd press → close, but must WAIT (don't free a live surface)
    XCTAssertEqual(
      store.runTabID(for: t.id), tab, "2nd Stop must not close while the process is alive")

    view.liveProcessOverrideForTesting = false  // process exits
    settle()
    XCTAssertNil(store.runTabID(for: t.id), "tab closes once the process has exited")
    XCTAssertFalse(store.isRunCommandRunning(for: t.id))
  }

  func testRequestCloseWaitsForLiveRunCommand() {
    let previous = Defaults[.confirmOnCloseTerminal]
    Defaults[.confirmOnCloseTerminal] = false  // skip the modal (can't run in a unit test)
    defer { Defaults[.confirmOnCloseTerminal] = previous }

    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let tab = try! XCTUnwrap(store.runTabID(for: t.id))
    let view = try! XCTUnwrap(runView(store, t))
    view.liveProcessOverrideForTesting = true

    store.requestCloseTerminalTab(tab, for: t)
    XCTAssertEqual(store.runTabID(for: t.id), tab, "closing waits for the live run process to exit")

    view.liveProcessOverrideForTesting = false
    settle()
    XCTAssertNil(store.runTabID(for: t.id), "tab closes once the process has exited")
  }

  func testGracefullyStopAllWaitsForEveryLiveCommandThenCompletes() {
    let store = makeStore([project("/a", workrooms: ["main", "two"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t1 = target(store, "/a", "main")
    let t2 = target(store, "/a", "two")
    store.startRunCommand(for: t1)
    store.startRunCommand(for: t2)
    let v1 = try! XCTUnwrap(runView(store, t1))
    let v2 = try! XCTUnwrap(runView(store, t2))
    v1.liveProcessOverrideForTesting = true
    v2.liveProcessOverrideForTesting = true
    XCTAssertTrue(store.hasLiveRunCommand)

    var completed = false
    store.gracefullyStopAllRunCommands(timeout: 2) { completed = true }
    XCTAssertFalse(completed, "waits while processes are alive")

    v1.liveProcessOverrideForTesting = false  // only one exited
    settle(0.2)
    XCTAssertFalse(completed, "still waiting on the second run command")

    v2.liveProcessOverrideForTesting = false  // both exited
    settle(0.2)
    XCTAssertTrue(completed, "completes once every run command has exited")
  }

  func testGracefullyStopAllCompletesImmediatelyWhenNothingLive() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    store.startRunCommand(for: target(store, "/a", "main"))  // no override → no live PTY
    XCTAssertFalse(store.hasLiveRunCommand)

    var completed = false
    store.gracefullyStopAllRunCommands(timeout: 2) { completed = true }
    XCTAssertTrue(completed, "no live process → completes synchronously")
  }

  func testGracefullyStopAllFallsBackAfterTimeout() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let v = try! XCTUnwrap(runView(store, t))
    v.liveProcessOverrideForTesting = true  // a wedged server that never exits

    var completed = false
    store.gracefullyStopAllRunCommands(timeout: 0.2) { completed = true }
    XCTAssertFalse(completed)
    settle(0.5)
    XCTAssertTrue(completed, "a wedged process still proceeds after the timeout (SIGHUP fallback)")
  }

  // MARK: Background run, status outcomes, run toast (issue #67)

  func testStartRunsInBackgroundWithoutStealingFocus() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    let shell = store.terminals.addTab(for: t).id  // a tab the user is on (addTab focuses it)

    store.startRunCommand(for: t)  // issue #67: starts in the background

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertEqual(
      store.terminals.activeTab(for: t)?.id, shell, "a background start must not steal focus")
    XCTAssertNotEqual(store.terminals.activeTab(for: t)?.id, store.runTabID(for: t.id))
  }

  func testToggleStartDoesNotNavigate() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = nil  // unrelated selection state

    store.toggleRunCommand(for: t)  // sidebar ▶ → start

    XCTAssertTrue(store.isRunCommandRunning(for: t.id))
    XCTAssertNil(store.selectedTargetID, "issue #67: starting from the sidebar must not navigate")
  }

  func testCleanExitMapsToExitedOutcome() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    runView(store, t)?.handleChildExited(exitCode: 0)

    XCTAssertEqual(store.runOutcomes[t.id], .exited(code: 0))
  }

  func testNonZeroExitMapsToFailedOutcome() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    runView(store, t)?.handleChildExited(exitCode: 137)

    XCTAssertEqual(
      store.runOutcomes[t.id], .exited(code: 137), "a non-zero exit is recorded as such")
  }

  func testUserStopThenExitMapsToStopped() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    store.stopRunCommand(for: t)  // 1st press → SIGINT, marks .running(interrupted: true)
    runView(store, t)?.handleChildExited(exitCode: 0)  // process then exits

    XCTAssertEqual(store.runOutcomes[t.id], .stoppedByUser, "a user Stop is not a failure")
  }

  func testRunToastShownWhenBackgroundedHiddenWhenViewing() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t)  // a focused shell, so the run isn't the visible tab

    store.startRunCommand(for: t)  // background
    XCTAssertEqual(store.runToastItems.map(\.targetID), [t.id], "a backgrounded run shows a toast")
    XCTAssertEqual(store.runToastItems.first?.status, .running)

    // Open the run terminal → it becomes the visible tab → the toast hides (not dismissed).
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.terminals.focus(runID, for: t)
    XCTAssertTrue(store.runToastItems.isEmpty, "no toast for the run you're looking at")
  }

  func testLiveRunToastOnlyForSelectedWorkroom() {
    // issue #73: two workrooms running in the background must not pop a live toast each — only the
    // selected workroom's backgrounded run shows a "running" toast; the other's stays silent.
    let store = makeStore([project("/a", workrooms: ["main", "two"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t1 = target(store, "/a", "main")
    let t2 = target(store, "/a", "two")

    // main selected, both runs backgrounded (a focused shell on each, so neither run is visible).
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t1)
    _ = store.terminals.addTab(for: t2)
    store.startRunCommand(for: t2)  // the other workroom's run, started first
    store.startRunCommand(for: t1)  // the selected workroom's run

    XCTAssertEqual(
      store.runToastItems.map(\.targetID), [t1.id],
      "only the selected workroom's live run toasts — not every open workroom (issue #73)")

    // Switch selection → the toast follows the selected workroom, still just one.
    store.selectedTargetID = .workroom(project: "/a", name: "two")
    XCTAssertEqual(
      store.runToastItems.map(\.targetID), [t2.id],
      "the live toast tracks the selected workroom, never both at once")
  }

  func testDismissRunToastHidesItWithoutStoppingTheRun() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t)
    store.startRunCommand(for: t)
    XCTAssertFalse(store.runToastItems.isEmpty)

    store.dismissRunToast(for: t.id)

    XCTAssertTrue(store.runToastItems.isEmpty, "✕ dismisses the toast")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id), "but the run keeps running")
  }

  func testRunOrFocusFocusesAnAlreadyRunningBackgroundRun() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    let shell = store.terminals.addTab(for: t).id
    store.startRunCommand(for: t)  // background; the shell stays focused
    XCTAssertEqual(store.terminals.activeTab(for: t)?.id, shell)

    store.runOrFocusRunCommand()  // ⌘R while running → "show me the run"

    XCTAssertEqual(
      store.terminals.activeTab(for: t)?.id, store.runTabID(for: t.id),
      "⌘R on a running background run focuses it")
  }

  func testRestartPreservesFocusWhenRunTabWasFocused() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.terminals.focus(runID, for: t)  // user opened the run terminal

    store.restartRunCommand(for: t)  // running → Ctrl-C → restarting
    runView(store, t)?.handleChildExited(exitCode: 0)  // exit → deferred close + respawn
    let pumped = expectation(description: "deferred respawn")
    DispatchQueue.main.async { pumped.fulfill() }
    wait(for: [pumped], timeout: 1)

    let newRun = try! XCTUnwrap(store.runTabID(for: t.id))
    XCTAssertEqual(
      store.terminals.activeTab(for: t)?.id, newRun,
      "restart keeps the run focused when it was focused (codex correction)")
  }

  func testBackgroundRestartStaysBackground() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    let shell = store.terminals.addTab(for: t).id  // focused
    store.startRunCommand(for: t)  // background
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    XCTAssertEqual(store.terminals.activeTab(for: t)?.id, shell)

    store.restartRunCommand(for: t)  // running → Ctrl-C → restarting
    runView(store, t)?.handleChildExited(exitCode: 0)  // exit → deferred close + respawn
    let pumped = expectation(description: "deferred respawn")
    DispatchQueue.main.async { pumped.fulfill() }
    wait(for: [pumped], timeout: 1)

    let newRun = try! XCTUnwrap(store.runTabID(for: t.id))
    XCTAssertNotEqual(newRun, runID, "restart spawns a fresh tab")
    XCTAssertEqual(
      store.terminals.activeTab(for: t)?.id, shell,
      "a background restart stays backgrounded — focus stays on the shell")
  }

  func testRunVisibleInSplitHidesToastEvenWhenNotFocused() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    store.startRunCommand(for: t)  // background
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    let sibling = store.terminals.addTab(for: t).id
    // Split [sibling, run] — both panes visible at once.
    store.terminals.moveTabIntoSplit(runID, ontoEdge: .right, of: sibling, for: t)
    store.terminals.focus(sibling, for: t)  // focus the sibling, not the run

    XCTAssertTrue(
      store.runToastItems.isEmpty,
      "a run visible in a split hides its toast even when the sibling is focused (split-aware)")
  }

  func testFailedToStartWhenSurfaceSpawnFails() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    // Simulate `ghostty_surface_new` returning nil for the backgrounded run surface.
    store.terminals.makeView = { _, cwd, command in
      let v = GhosttySurfaceView(workingDirectory: cwd, command: command, spawnsSurface: false)
      v.spawnFailOverrideForTesting = true
      return v
    }
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")

    store.startRunCommand(for: t)  // background; spawn "fails"

    XCTAssertFalse(store.isRunCommandRunning(for: t.id), "a failed spawn is not 'running'")
    XCTAssertEqual(store.runOutcomes[t.id], .failedToStart)
    XCTAssertEqual(
      store.runToastItems.first?.status, .failedToStart, "the toast surfaces the failure, not a lie"
    )
  }

  func testRunToastAutoDismissesAfterTerminalState() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    var pending: [DispatchWorkItem] = []
    store.scheduleRunToastDismiss = { _, body in
      let work = DispatchWorkItem(block: body)
      pending.append(work)
      return work
    }
    store.startRunCommand(for: t)  // background (no selection → no live toast; terminal toast below)

    runView(store, t)?.handleChildExited(exitCode: 0)  // terminal → schedules the auto-dismiss
    XCTAssertEqual(pending.count, 1)
    XCTAssertFalse(store.runToastItems.isEmpty, "the toast lingers right after the run ends")

    pending[0].perform()  // the linger elapses
    XCTAssertTrue(store.runToastItems.isEmpty, "the toast auto-dismisses after the linger")
  }

  func testRestartCancelsStaleAutoDismissTimer() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    var pending: [DispatchWorkItem] = []
    store.scheduleRunToastDismiss = { _, body in
      let work = DispatchWorkItem(block: body)
      pending.append(work)
      return work
    }
    store.startRunCommand(for: t)
    runView(store, t)?.handleChildExited(exitCode: 0)  // .stopped → schedules pending[0]
    XCTAssertEqual(pending.count, 1)

    store.restartRunCommand(for: t)  // .stopped → respawn → resetRunToast cancels the stale timer

    XCTAssertTrue(pending[0].isCancelled, "restart cancels the stale auto-dismiss timer")
    XCTAssertTrue(store.isRunCommandRunning(for: t.id), "and the fresh run is running")
  }

  func testRunOutcomeBannerWorthiness() {
    // A genuine failure warrants a banner; a clean exit or a user Stop does not (Arch #7).
    XCTAssertTrue(AppStore.runOutcomeIsBannerWorthy(.exited(code: 1)))
    XCTAssertTrue(AppStore.runOutcomeIsBannerWorthy(.exited(code: 137)))
    XCTAssertTrue(AppStore.runOutcomeIsBannerWorthy(.failedToStart))
    XCTAssertFalse(AppStore.runOutcomeIsBannerWorthy(.exited(code: 0)))
    XCTAssertFalse(AppStore.runOutcomeIsBannerWorthy(.stoppedByUser))
    XCTAssertFalse(AppStore.runOutcomeIsBannerWorthy(nil))
  }

  func testTappingRunToastOpensTheRunAndDismissesIt() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    _ = store.terminals.addTab(for: t)  // focused shell → the run is backgrounded + toasted
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    XCTAssertFalse(store.runToastItems.isEmpty)

    // What a card tap fires (see ToastStack): open the run terminal AND dismiss the toast.
    store.openRunToast(for: t.id)
    store.dismissRunToast(for: t.id)

    XCTAssertEqual(store.terminals.activeTab(for: t)?.id, runID, "the tap opens the run terminal")
    XCTAssertTrue(store.dismissedRunToasts.contains(t.id), "the tap dismisses the toast for good")
    XCTAssertTrue(store.runToastItems.isEmpty)
  }

  // MARK: Success/failure detection (issue #79)

  func testRunOutcomeIsFailure() {
    XCTAssertFalse(AppStore.RunOutcome.exited(code: 0).isFailure, "a clean exit is not a failure")
    XCTAssertTrue(AppStore.RunOutcome.exited(code: 1).isFailure)
    XCTAssertTrue(AppStore.RunOutcome.exited(code: 137).isFailure)
    XCTAssertTrue(AppStore.RunOutcome.failedToStart.isFailure)
    XCTAssertFalse(AppStore.RunOutcome.stoppedByUser.isFailure, "a user stop is not a failure")
  }

  func testRunFailedTracksOutcome() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    XCTAssertFalse(store.runFailed(for: t.id), "no run yet → not failed")
    store.startRunCommand(for: t)
    XCTAssertFalse(store.runFailed(for: t.id), "running → not failed")
    runView(store, t)?.handleChildExited(exitCode: 1)
    XCTAssertTrue(store.runFailed(for: t.id), "a non-zero self-exit → failed (drives the red icon)")
  }

  func testCleanExitIsNotFailed() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    runView(store, t)?.handleChildExited(exitCode: 0)
    XCTAssertFalse(store.runFailed(for: t.id), "a clean exit shows no red icon")
  }

  func testFailureToastShowsEvenWhenViewingRunTab() {
    // #79: terminal-state toasts bypass the hide-when-visible rule (live toasts keep it).
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.terminals.focus(runID, for: t)  // viewing the run tab
    XCTAssertTrue(store.runToastItems.isEmpty, "no LIVE toast for the tab you're watching")

    runView(store, t)?.handleChildExited(exitCode: 1)
    XCTAssertEqual(
      store.runToastItems.first?.status, .failed(code: 1),
      "a failure toast shows even on the focused run tab (#79 always-show)")
  }

  func testSuccessToastShowsEvenWhenViewingRunTab() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.selectedTargetID = .workroom(project: "/a", name: "main")
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    store.terminals.focus(runID, for: t)

    runView(store, t)?.handleChildExited(exitCode: 0)
    XCTAssertEqual(
      store.runToastItems.first?.status, .exited,
      "a success toast shows even on the focused run tab")
  }

  func testUserStopShowsNoToast() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    store.stopRunCommand(for: t)  // 1st press → interrupted
    runView(store, t)?.handleChildExited(exitCode: 0)

    XCTAssertEqual(store.runOutcomes[t.id], .stoppedByUser)
    XCTAssertTrue(store.runToastItems.isEmpty, "a user-initiated stop shows no toast (#79)")
    XCTAssertFalse(store.runFailed(for: t.id), "and no red icon")
  }

  func testRestartShowsNoTerminalToast() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    store.restartRunCommand(for: t)  // running → Ctrl-C → .restarting

    XCTAssertFalse(
      store.runToastItems.contains { $0.status.isTerminal },
      "a restart never surfaces a success/failure toast (#79)")
  }

  func testInPaneCtrlCMarksInterruptedThenNoToast() {
    // ⌃C typed into the run terminal (not the Stop button): the surface forwards SIGINT; the host's
    // onInterrupt → markRunInterruptedByKey flips `interrupted`, so the exit reads as a user stop
    // regardless of code (#79).
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    store.markRunInterruptedByKey(for: t)
    runView(store, t)?.handleChildExited(exitCode: 130)  // non-zero, from SIGINT

    XCTAssertEqual(store.runOutcomes[t.id], .stoppedByUser, "in-pane ⌃C is a stop, not a failure")
    XCTAssertFalse(store.runFailed(for: t.id), "so no red icon, whatever the exit code")
    XCTAssertTrue(store.runToastItems.isEmpty, "and no toast")
  }

  func testMarkInterruptedByKeyIsNoOpWhenNotRunning() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.markRunInterruptedByKey(for: t)  // armed/none → no crash, no state created
    XCTAssertNil(store.runStates[t.id])

    store.startRunCommand(for: t)
    runView(store, t)?.handleChildExited(exitCode: 1)  // already .stopped
    store.markRunInterruptedByKey(for: t)  // must not rewrite a finished run
    XCTAssertTrue(
      store.runFailed(for: t.id), "a key event after the run ended doesn't erase failure")
  }

  func testRunExitCodePrefersWrapperFileOverLibghostty() {
    // libghostty's child-exit code is unreliable (GhosttyKit 1.2.3 reports 0), so markRunExited reads
    // the code the wrapper recorded to a file. Simulate that file; libghostty reports a bogus 0.
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "exit 7", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let pidPath = try! XCTUnwrap(store.runPidFiles[t.id])
    try! "7".write(
      toFile: AppStore.runExitPath(forPidPath: pidPath), atomically: true, encoding: .utf8)

    runView(store, t)?.handleChildExited(exitCode: 0)  // libghostty's bogus 0

    XCTAssertEqual(
      store.runOutcomes[t.id], .exited(code: 7),
      "the wrapper-recorded code wins over libghostty's 0")
    XCTAssertTrue(store.runFailed(for: t.id), "so the failure indicators light up (#79)")
  }

  func testRunExitCodeFallsBackToLibghosttyWhenNoFile() {
    // No recorded file (e.g. the command was signalled before it could write one) → use libghostty's.
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)

    runView(store, t)?.handleChildExited(exitCode: 0)  // no exit file written in tests

    XCTAssertEqual(store.runOutcomes[t.id], .exited(code: 0), "falls back to libghostty's code")
    XCTAssertFalse(store.runFailed(for: t.id))
  }

  func testClosingRunTabClearsFailureOutcome() {
    let store = makeStore([project("/a", workrooms: ["main"])])
    store.setRunConfig(RunConfig(command: "echo hi", autoRun: false), forProject: "/a")
    let t = target(store, "/a", "main")
    store.startRunCommand(for: t)
    let runID = try! XCTUnwrap(store.runTabID(for: t.id))
    runView(store, t)?.handleChildExited(exitCode: 1)
    XCTAssertTrue(store.runFailed(for: t.id))

    store.terminals.closeTab(runID, for: t)

    XCTAssertNil(store.runOutcomes[t.id], "closing the run tab clears the outcome (#79)")
    XCTAssertFalse(store.runFailed(for: t.id), "so the red icon resets")
  }
}
