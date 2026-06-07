import XCTest

/// Split-pane UI tests (issue #3). These drive the real app through XCUITest — which owns app launch
/// and routes key commands to the app itself — and assert on the **on-screen pane count**. A terminal
/// surface appears in the accessibility tree only while it's actually mounted in a window, so counting
/// `terminal.surface` elements is a direct "how many panes are rendering?" check. That's the signal
/// that catches the close-a-split-pane blank regression: the survivor must remain a rendered pane, not
/// a detached/blank one.
///
/// Opportunistic (like `WorkroomWorkflowUITests`): the app loads the real `~/.config/workroom`, so
/// these `XCTSkip` when no project/workroom is configured. Run with `make app-uitest` on a GUI session.
final class SplitPaneUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    // Skip the close/quit confirmation dialogs so ⌘W closes synchronously and teardown doesn't block.
    app.launchArguments += ["-confirmOnCloseTerminal", "0", "-confirmOnQuit", "0"]
    app.launch()
    return app
  }

  private func surfaces(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "terminal.surface")
  }

  private func tabs(_ app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
  }

  private func assertCount(_ q: XCUIElementQuery, reaches n: Int, timeout: TimeInterval = 6) {
    let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", n), object: q)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "count did not reach \(n) within \(timeout)s")
  }

  /// Open the first available workroom so a terminal renders; skip if none configured.
  private func openWorkroom(_ app: XCUIApplication) throws {
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let projects = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.project."))
    guard projects.firstMatch.waitForExistence(timeout: 5) else {
      throw XCTSkip("No projects configured — UI split tests need a workroom.")
    }
    projects.element(boundBy: 0).click()
    let workrooms = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.workroom."))
    guard workrooms.firstMatch.waitForExistence(timeout: 3) else {
      throw XCTSkip("No workrooms configured — UI split tests need a workroom.")
    }
    workrooms.element(boundBy: 0).click()
    XCTAssertTrue(
      surfaces(app).firstMatch.waitForExistence(timeout: 6),
      "selecting a workroom should render a terminal pane")
  }

  func testSplitRightCreatesTwoPanes() throws {
    let app = launchedApp()
    try openWorkroom(app)
    assertCount(surfaces(app), reaches: 1)
    app.typeKey("d", modifierFlags: .command)  // ⌘D → Split Right
    assertCount(surfaces(app), reaches: 2)
  }

  /// Regression for the close-collapse blank bug: closing one pane of a split must leave exactly one
  /// rendered pane (the survivor), not a detached/blank surface.
  func testCloseSplitPaneLeavesOneRenderedPane() throws {
    let app = launchedApp()
    try openWorkroom(app)
    app.typeKey("d", modifierFlags: .command)
    assertCount(surfaces(app), reaches: 2)
    app.typeKey("w", modifierFlags: .command)  // close the focused (new) pane → collapse to solo
    assertCount(surfaces(app), reaches: 1)  // survivor still renders
  }

  func testNestedSplitCreatesThreePanes() throws {
    let app = launchedApp()
    try openWorkroom(app)
    app.typeKey("d", modifierFlags: .command)
    assertCount(surfaces(app), reaches: 2)
    app.typeKey("d", modifierFlags: [.command, .shift])  // ⇧⌘D → Split Down (nested)
    assertCount(surfaces(app), reaches: 3)
  }

  /// The issue's "terminal tabs should remain for each terminal, even if it is in a pane."
  func testSplitKeepsATabPerTerminal() throws {
    let app = launchedApp()
    try openWorkroom(app)
    let initial = tabs(app).count
    app.typeKey("d", modifierFlags: .command)
    assertCount(surfaces(app), reaches: 2)
    assertCount(tabs(app), reaches: initial + 1)  // the split's new terminal has its own strip tab
  }

  /// Regression: closing a pane from its own right-click menu must not crash the app. The
  /// `rightMouseDown` handler balances its press with a RELEASE *after* the menu closes; closing the
  /// pane used to free the surface mid-modal, so that RELEASE hit a freed surface (use-after-free).
  func testRightClickCloseTerminalDoesNotCrash() throws {
    let app = launchedApp()
    try openWorkroom(app)
    app.typeKey("d", modifierFlags: .command)  // split → two panes
    assertCount(surfaces(app), reaches: 2)

    surfaces(app).firstMatch.rightClick()
    let close = app.menuItems["Close Terminal"]
    XCTAssertTrue(close.waitForExistence(timeout: 3), "right-click menu should offer Close Terminal")
    close.click()

    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: 3), "app must stay alive after Close Terminal")
    assertCount(surfaces(app), reaches: 1)  // collapsed to the survivor, no crash
  }
}
