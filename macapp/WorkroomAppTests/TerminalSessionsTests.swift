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
    sessions.makeView = { GhosttySurfaceView(workingDirectory: $0.path) }
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
}
