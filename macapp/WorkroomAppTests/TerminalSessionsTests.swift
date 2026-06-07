import XCTest

@testable import Workroom

/// Lifecycle tests for the rewritten `TerminalSessions` (plan T1). The factory seam lets us exercise
/// add/close/select/move/reap without spawning real shells: a `GhosttySurfaceView` only creates its
/// PTY when it enters a window, so constructing one here is inert.
@MainActor
final class TerminalSessionsTests: XCTestCase {
  private let target = TerminalTarget(id: "wr|/p|foo", title: "foo", path: "/tmp", isMissing: false)

  private func makeSessions() -> TerminalSessions {
    let sessions = TerminalSessions()
    sessions.makeView = { _, cwd in GhosttySurfaceView(workingDirectory: cwd) }
    return sessions
  }

  func testAddTabAppendsAndActivates() {
    let s = makeSessions()
    s.addTab(for: target)
    XCTAssertEqual(s.tabs(for: target).count, 1)
    XCTAssertEqual(s.activeTab(for: target)?.id, s.tabs(for: target).first?.id)
    XCTAssertEqual(s.tabs(for: target).first?.title, "Terminal 1")
  }

  func testEnsureTabIsIdempotent() {
    let s = makeSessions()
    s.ensureTab(for: target)
    s.ensureTab(for: target)
    XCTAssertEqual(s.tabs(for: target).count, 1)
  }

  func testTitlesIncrementAndDoNotRenumber() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.addTab(for: target)
    XCTAssertEqual(s.tabs(for: target).map(\.title), ["Terminal 1", "Terminal 2", "Terminal 3"])
    let second = s.tabs(for: target)[1].id
    s.closeTab(second, for: target)
    s.addTab(for: target)
    // Counter keeps climbing; titles stay stable rather than renumbering.
    XCTAssertEqual(s.tabs(for: target).map(\.title), ["Terminal 1", "Terminal 3", "Terminal 4"])
  }

  func testCloseActiveSelectsNeighborThatSlidIn() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.addTab(for: target)
    let first = s.tabs(for: target)[0].id
    s.select(first, for: target)
    s.closeTab(first, for: target)
    // The neighbour that slid into slot 0 (originally "Terminal 2") becomes active.
    XCTAssertEqual(s.activeTab(for: target)?.title, "Terminal 2")
    XCTAssertEqual(s.tabs(for: target).count, 2)
  }

  func testCloseLastLeavesNoActive() {
    let s = makeSessions()
    s.addTab(for: target)
    let only = s.tabs(for: target)[0].id
    s.closeTab(only, for: target)
    XCTAssertTrue(s.tabs(for: target).isEmpty)
    XCTAssertNil(s.activeTab(for: target))
  }

  func testMoveTabClampsToBounds() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.addTab(for: target)
    let first = s.tabs(for: target)[0].id  // "Terminal 1"
    s.moveTab(first, toIndex: 99, for: target)
    XCTAssertEqual(s.tabs(for: target).map(\.title), ["Terminal 2", "Terminal 3", "Terminal 1"])
  }

  func testReapClearsTabsActiveAndCounter() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.reap(target.id)
    XCTAssertTrue(s.tabs(for: target).isEmpty)
    XCTAssertNil(s.activeTab(for: target))
    // Counter reset: the next tab is "Terminal 1" again.
    s.addTab(for: target)
    XCTAssertEqual(s.tabs(for: target).first?.title, "Terminal 1")
  }

  // MARK: Running state (issue #28)

  func testIsRunningTracksCommandLifecycle() {
    let s = makeSessions()
    s.addTab(for: target)
    let tab = s.tabs(for: target).first!

    // A fresh tab sits at the prompt — nothing running.
    XCTAssertFalse(s.tabs(for: target).first!.isRunning)
    XCTAssertFalse(s.isRunning(forTargetID: target.id))

    // A command's title (preexec) marks it running…
    tab.view.onTitleChange?("npm run dev")
    XCTAssertTrue(s.tabs(for: target).first!.isRunning)
    XCTAssertTrue(s.isRunning(forTargetID: target.id))

    // …and command_finished returns it to idle.
    tab.view.onCommandFinished?()
    XCTAssertFalse(s.tabs(for: target).first!.isRunning)
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
  }

  func testDirectoryTitlesDoNotCountAsRunning() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.view
    view.handlePwd("/var/data/proj")  // cwd outside $HOME, so its `~` form is itself

    // The directory title the shell sets at the prompt isn't a command — still idle.
    view.onTitleChange?("/var/data/proj")
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
  }

  func testIsRunningAggregatesAcrossTabs() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)

    // A command in the second tab makes the whole target "running".
    s.tabs(for: target)[1].view.onTitleChange?("make build")
    XCTAssertTrue(s.isRunning(forTargetID: target.id))

    // It clears once that tab finishes (the first never ran).
    s.tabs(for: target)[1].view.onCommandFinished?()
    XCTAssertFalse(s.isRunning(forTargetID: target.id))
  }

  func testUnknownTargetIsNotRunning() {
    let s = makeSessions()
    XCTAssertFalse(s.isRunning(forTargetID: "wr|/p|never-opened"))
  }

  // MARK: Live titles (issue #2)

  func testRunningCommandShowsThenClearsWhenFinished() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.view

    // A running command takes over from the default…
    view.onTitleChange?("npm run dev")
    XCTAssertEqual(s.tabs(for: target).first?.title, "npm run dev")

    // …a later command wins…
    view.onTitleChange?("vim README.md")
    XCTAssertEqual(s.tabs(for: target).first?.title, "vim README.md")

    // …and finishing the command falls back to the default "Terminal N".
    view.onCommandFinished?()
    XCTAssertEqual(s.tabs(for: target).first?.title, "Terminal 1")
  }

  func testDirectoryTitlesAreIgnoredSoTheCommandSurvives() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.view
    view.handlePwd("/var/data/proj")  // cwd outside $HOME, so its `~` form is itself

    // The directory title the shell sets at the prompt is ignored → default stays.
    view.onTitleChange?("/var/data/proj")
    XCTAssertEqual(s.tabs(for: target).first?.title, "Terminal 1")

    // The command shows…
    view.onTitleChange?("sleep 5")
    XCTAssertEqual(s.tabs(for: target).first?.title, "sleep 5")

    // …and a directory title fired *during* the command doesn't clobber it.
    view.onTitleChange?("/var/data/proj")
    XCTAssertEqual(s.tabs(for: target).first?.title, "sleep 5")
  }

  func testSurfaceTitleIsScopedToItsOwnTab() {
    let s = makeSessions()
    s.addTab(for: target)
    s.addTab(for: target)
    s.tabs(for: target)[1].view.onTitleChange?("vim")
    XCTAssertEqual(s.tabs(for: target).map(\.title), ["Terminal 1", "vim"])
  }

  func testIsDirectoryTitleRecognizesPromptTitlesButNotCommands() {
    let home = "/Users/me"
    let cwd = "/Users/me/dev/codaset"
    // Directory / prompt titles in every form the shell emits:
    XCTAssertTrue(TerminalSessions.isDirectoryTitle(cwd, cwd: cwd, home: home))
    XCTAssertTrue(TerminalSessions.isDirectoryTitle("~/dev/codaset", cwd: cwd, home: home))
    XCTAssertTrue(
      TerminalSessions.isDirectoryTitle("me@MacBookPro:~/dev/codaset", cwd: cwd, home: home))
    // Real commands are not directory titles:
    XCTAssertFalse(TerminalSessions.isDirectoryTitle("sleep 5", cwd: cwd, home: home))
    XCTAssertFalse(TerminalSessions.isDirectoryTitle("vim README.md", cwd: cwd, home: home))
    XCTAssertFalse(TerminalSessions.isDirectoryTitle("make: build failed", cwd: cwd, home: home))
    // No cwd yet → can't classify, so nothing is treated as a directory.
    XCTAssertFalse(TerminalSessions.isDirectoryTitle("~/dev/codaset", cwd: nil, home: home))
  }

  // MARK: Splits (issue #3)

  func testSplitFocusedPaneFormsSplitAndFocusesNew() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)

    let tabs = s.tabs(for: target)
    XCTAssertEqual(tabs.count, 2)
    XCTAssertEqual(tabs.first?.id, a)  // existing pane stays first
    XCTAssertEqual(s.split(for: target)?.tabIDs.count, 2)
    XCTAssertEqual(s.activeTab(for: target)?.id, tabs.last?.id)  // the new pane is focused
    XCTAssertTrue(s.isSplitVisible(for: target))
  }

  func testSplitInheritsFocusedPaneCwd() {
    var cwds: [String] = []
    let s = TerminalSessions()
    s.makeView = { _, cwd in
      cwds.append(cwd)
      return GhosttySurfaceView(workingDirectory: cwd)
    }
    s.addTab(for: target)  // first surface spawns at the target path
    s.tabs(for: target).first!.view.handlePwd("/work/here")
    s.splitFocusedPane(for: target, orientation: .horizontal)
    XCTAssertEqual(cwds.count, 2)
    XCTAssertEqual(cwds.last, "/work/here")  // the split inherits the focused pane's cwd
  }

  func testSplitRefusedWhenPaneTooSmall() {
    let s = makeSessions()
    s.addTab(for: target)
    let view = s.tabs(for: target).first!.view
    view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)  // < 2 × minPaneSize
    s.splitFocusedPane(for: target, orientation: .horizontal)
    XCTAssertEqual(s.tabs(for: target).count, 1)  // refused — no sliver
    XCTAssertNil(s.split(for: target))
  }

  func testClosePaneCollapsesSplitToSibling() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)
    let ids = s.tabs(for: target).map(\.id)  // [A, B], B focused
    s.closeTab(ids[1], for: target)
    XCTAssertEqual(s.tabs(for: target).count, 1)
    XCTAssertNil(s.split(for: target))  // dropped to a lone tab → no split
    XCTAssertEqual(s.activeTab(for: target)?.id, ids[0])  // sibling focused
    // The survivor is the only on-screen surface — occlusion must keep it visible (issue #3: closing
    // a split pane left the survivor blank when the view layer mishandled the re-home).
    XCTAssertEqual(s.visibleTabIDs(for: target), [ids[0]])
  }

  func testNewSplitFromSoloDissolvesPrevious() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // split [A, B]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id  // C solo, focused — not in the split
    XCTAssertFalse(s.isSplitVisible(for: target))
    s.splitFocusedPane(for: target, orientation: .vertical)  // new split from C
    let split = s.split(for: target)!
    XCTAssertEqual(split.tabIDs.count, 2)
    XCTAssertTrue(split.contains(c))
    XCTAssertFalse(split.contains(a))
    XCTAssertFalse(split.contains(b))  // only one split exists at a time
  }

  func testVisibleTabIDsTracksSplitVsSolo() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    XCTAssertEqual(s.visibleTabIDs(for: target), [a])
    s.splitFocusedPane(for: target, orientation: .horizontal)
    XCTAssertEqual(Set(s.visibleTabIDs(for: target)), Set(s.split(for: target)!.tabIDs))
    let c = s.addTab(for: target).id  // focusing a fresh solo tab hides the split
    XCTAssertEqual(s.visibleTabIDs(for: target), [c])
    XCTAssertFalse(s.isSplitVisible(for: target))
  }

  func testSplitMembersStayContiguousInStrip() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    _ = s.addTab(for: target)  // a second solo tab after A in the loose order
    s.focus(a, for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // split A | new
    let order = s.tabs(for: target).map(\.id)
    let memberIdxs = s.split(for: target)!.tabIDs.compactMap { order.firstIndex(of: $0) }.sorted()
    XCTAssertEqual(memberIdxs.count, 2)
    XCTAssertEqual(memberIdxs[1] - memberIdxs[0], 1)  // the two members render adjacent
  }

  // MARK: Drag-and-drop (issue #3, Phase 2)

  func testMoveTabOntoRightEdgeFormsSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id  // solo
    s.moveTabIntoSplit(c, ontoEdge: .right, of: a, for: target)
    XCTAssertEqual(s.split(for: target)?.tabIDs, [a, c])  // dropped on the right → second
    XCTAssertEqual(s.activeTab(for: target)?.id, c)  // the moved tab is focused
    XCTAssertTrue(s.isSplitVisible(for: target))
  }

  func testMoveTabOntoLeftEdgePlacesDroppedFirst() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id
    s.moveTabIntoSplit(c, ontoEdge: .left, of: a, for: target)
    XCTAssertEqual(s.split(for: target)?.tabIDs, [c, a])  // left drop → leading
  }

  func testMoveTabJoinsExistingSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id  // solo
    s.moveTabIntoSplit(c, ontoEdge: .bottom, of: b, for: target)
    XCTAssertEqual(Set(s.split(for: target)!.tabIDs), Set([a, b, c]))
    XCTAssertEqual(s.split(for: target)!.tabIDs.count, 3)
  }

  func testStartingSplitFromTwoSolosDissolvesOld() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    let b = s.activeTab(for: target)!.id
    let c = s.addTab(for: target).id  // solo
    let d = s.addTab(for: target).id  // solo
    s.moveTabIntoSplit(d, ontoEdge: .right, of: c, for: target)  // fresh split (c, d)
    let split = s.split(for: target)!
    XCTAssertEqual(split.tabIDs, [c, d])
    XCTAssertFalse(split.contains(a))
    XCTAssertFalse(split.contains(b))  // single-split invariant: old split dissolved
  }

  func testExtractFromSplitMakesItSolo() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    s.splitFocusedPane(for: target, orientation: .vertical)  // [a, b, c], c focused
    let c = s.activeTab(for: target)!.id
    s.extractFromSplit(c, for: target)
    XCTAssertFalse(s.split(for: target)!.contains(c))
    XCTAssertEqual(s.split(for: target)!.tabIDs.count, 2)
    XCTAssertEqual(s.activeTab(for: target)?.id, c)  // extracted tab is solo + focused
    XCTAssertFalse(s.isSplitVisible(for: target))
  }

  func testExtractSecondToLastDissolvesSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b]
    let b = s.activeTab(for: target)!.id
    s.extractFromSplit(b, for: target)
    XCTAssertNil(s.split(for: target))  // only one would remain → no split
    XCTAssertEqual(s.activeTab(for: target)?.id, b)
  }

  func testFocusAdjacentPaneMovesWithinSplit() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, orientation: .horizontal)  // [a, b], b focused
    let b = s.activeTab(for: target)!.id
    XCTAssertTrue(s.focusAdjacentPane(.left, for: target))
    XCTAssertEqual(s.activeTab(for: target)?.id, a)
    XCTAssertTrue(s.focusAdjacentPane(.right, for: target))
    XCTAssertEqual(s.activeTab(for: target)?.id, b)
    XCTAssertFalse(s.focusAdjacentPane(.right, for: target))  // nothing to the right of b
  }

  func testFocusAdjacentPaneNoSplitIsNoOp() {
    let s = makeSessions()
    s.addTab(for: target)
    XCTAssertFalse(s.focusAdjacentPane(.right, for: target))
  }

  func testSplitFocusedPaneLeftPlacesNewPaneFirst() {
    let s = makeSessions()
    s.addTab(for: target)
    let a = s.activeTab(for: target)!.id
    s.splitFocusedPane(for: target, edge: .left)
    let split = s.split(for: target)!
    XCTAssertEqual(split.tabIDs.count, 2)
    XCTAssertEqual(split.tabIDs.last, a)  // original is now on the right
    XCTAssertEqual(split.tabIDs.first, s.activeTab(for: target)?.id)  // new pane: leading + focused
  }
}
