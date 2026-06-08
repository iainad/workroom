import XCTest

/// Split-pane UI tests (issue #3). These drive the real app through XCUITest — which owns app launch
/// and routes key commands to the app itself — and assert on the **on-screen pane count**. Each leaf
/// of the pane renderer exposes one `terminal.pane` accessibility element (the libghostty Metal
/// surface itself contributes nothing to the a11y tree), so counting `terminal.pane` elements is a
/// direct "how many panes are rendering?" check. That's the signal that catches the close-a-split-pane
/// blank regression: the survivor must remain a rendered pane, not a detached/blank one.
///
/// Deterministic, not opportunistic: the app is launched in **UI-test fixture mode**
/// (`-WorkroomUITestFixture 1`, see `UITestFixture`), so it loads fake projects/workrooms rooted at a
/// temp directory instead of the developer's real `~/.config/workroom` — the fixture workroom is
/// auto-selected, so a terminal renders on launch with no sidebar navigation. Run with `make
/// app-uitest` on a GUI session (XCUITest can't drive a headless run).
final class SplitPaneUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    // Fixture mode: deterministic fake projects/workrooms (not the developer's real config), with the
    // close/quit confirmations suppressed in-app — so ⌘W closes synchronously and teardown never
    // blocks on an alert.
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launch()
    return app
  }

  /// On-screen panes: one `terminal.pane` accessibility element per rendered leaf.
  private func panes(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.pane")
  }

  /// One strip chip per terminal. The chip's title and close button both inherit the
  /// `terminal.tab.<title>` identifier, so match only the title StaticText to count chips 1:1.
  private func tabs(_ app: XCUIApplication) -> XCUIElementQuery {
    app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 6) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// Wait until the fixture workroom's terminal renders. The fixture auto-selects the workroom on
  /// launch, so this just confirms the first pane mounted — no sidebar clicking (and no XCTSkip:
  /// the fixture is always present).
  private func openWorkroom(_ app: XCUIApplication) throws {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    XCTAssertTrue(
      panes(app).firstMatch.waitForExistence(timeout: 10),
      "the fixture workroom should render a terminal pane on launch")
  }

  func testSplitRightCreatesTwoPanes() throws {
    let app = launchedApp()
    try openWorkroom(app)
    assertCount(panes(app), reaches: 1)
    app.typeKey("d", modifierFlags: .command)  // ⌘D → Split Right
    assertCount(panes(app), reaches: 2)
  }

  /// Regression for the close-collapse blank bug: closing one pane of a split must leave exactly one
  /// rendered pane (the survivor), not a detached/blank surface.
  func testCloseSplitPaneLeavesOneRenderedPane() throws {
    let app = launchedApp()
    try openWorkroom(app)
    app.typeKey("d", modifierFlags: .command)
    assertCount(panes(app), reaches: 2)
    app.typeKey("w", modifierFlags: .command)  // close the focused (new) pane → collapse to solo
    assertCount(panes(app), reaches: 1)  // survivor still renders
  }

  func testNestedSplitCreatesThreePanes() throws {
    let app = launchedApp()
    try openWorkroom(app)
    app.typeKey("d", modifierFlags: .command)
    assertCount(panes(app), reaches: 2)
    app.typeKey("d", modifierFlags: [.command, .shift])  // ⇧⌘D → Split Down (nested)
    assertCount(panes(app), reaches: 3)
  }

  /// The issue's "terminal tabs should remain for each terminal, even if it is in a pane."
  func testSplitKeepsATabPerTerminal() throws {
    let app = launchedApp()
    try openWorkroom(app)
    let initial = tabs(app).count
    app.typeKey("d", modifierFlags: .command)
    assertCount(panes(app), reaches: 2)
    assertCount(tabs(app), reaches: initial + 1)  // the split's new terminal has its own strip tab
  }

  /// Regression: closing a pane from its own right-click menu must not crash the app. The
  /// `rightMouseDown` handler balances its press with a RELEASE *after* the menu closes; closing the
  /// pane used to free the surface mid-modal, so that RELEASE hit a freed surface (use-after-free).
  func testRightClickCloseTerminalDoesNotCrash() throws {
    let app = launchedApp()
    try openWorkroom(app)
    app.typeKey("d", modifierFlags: .command)  // split → two panes
    assertCount(panes(app), reaches: 2)

    panes(app).firstMatch.rightClick()
    // "Close Terminal" titles two items — the right-click menu's AND the File-menu ⌘W command (which
    // lives in the collapsed menu bar with a zero frame). Click the on-screen, hittable one.
    let closeItems = app.menuItems.matching(NSPredicate(format: "title == %@", "Close Terminal"))
    XCTAssertTrue(
      closeItems.firstMatch.waitForExistence(timeout: 3),
      "right-click menu should offer Close Terminal")
    let close = closeItems.allElementsBoundByIndex.first { $0.isHittable } ?? closeItems.firstMatch
    close.click()

    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 3), "app must stay alive after Close Terminal")
    assertCount(panes(app), reaches: 1)  // collapsed to the survivor, no crash
  }
}
