import XCTest

/// App-shell workflow UI tests (XCUITest). These drive Workroom through the accessibility tree —
/// sidebar, tabs, menus, badges. They do NOT assert on terminal *content*: the libghostty surface
/// is Metal-rendered and its text isn't in the a11y tree until CMT-3 lands (then content-level
/// assertions become possible — see TODOS.md).
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run,
/// so these are intentionally excluded from `make app-test` (the unit gate) via a separate scheme.
///
/// Determinism caveat: the app loads the developer's real `~/.config/workroom`, so workflow tests
/// that need a project/workroom are **opportunistic** — they `XCTSkip` when none is present. Making
/// them deterministic (and CI-able) needs a UI-testing fixture seam in the app (a launch argument
/// that loads fake projects). See the "UI-testing fixture seam" TODO.
///
/// Still to add once the fixture seam exists: notification badge + click-to-navigate
/// (type `printf '\e]9;…\a'` → assert sidebar/tab badge → click → navigates) and
/// delete-workroom-clears-badges.
final class WorkroomWorkflowUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launch()
    return app
  }

  private func descendants(_ app: XCUIApplication, idPrefix: String) -> XCUIElementQuery {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", idPrefix))
  }

  private func assertCount(
    _ query: XCUIElementQuery, reaches expected: Int, timeout: TimeInterval = 4
  ) {
    let exp = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "count == %d", expected), object: query)
    XCTAssertEqual(
      XCTWaiter().wait(for: [exp], timeout: timeout), .completed,
      "element count did not reach \(expected) within \(timeout)s")
  }

  /// Deterministic smoke: the app launches and the shell chrome is present. No dependency on the
  /// developer's project config, so this always runs.
  func testAppLaunchesWithChrome() {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app did not reach foreground")
    XCTAssertGreaterThan(app.windows.count, 0, "expected a main window")
    XCTAssertTrue(
      app.descendants(matching: .any)["AddProject"].waitForExistence(timeout: 5),
      "the Add Project control should always be present in the sidebar")
  }

  /// Opportunistic: if a project + workroom exist, selecting the workroom opens a terminal tab and
  /// ⌘T / ⌘W add and close tabs. Skips when the environment has none.
  func testAddAndCloseTerminalTabs() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    // Workrooms are hidden until their project is expanded; expand the first project.
    let projects = descendants(app, idPrefix: "sidebar.project.")
    guard projects.firstMatch.waitForExistence(timeout: 5) else {
      throw XCTSkip(
        "No projects configured — add a UI-testing fixture seam for deterministic runs.")
    }
    projects.element(boundBy: 0).click()

    let workrooms = descendants(app, idPrefix: "sidebar.workroom.")
    guard workrooms.firstMatch.waitForExistence(timeout: 3) else {
      throw XCTSkip(
        "No workrooms configured — add a UI-testing fixture seam for deterministic runs.")
    }
    workrooms.element(boundBy: 0).click()

    let tabs = descendants(app, idPrefix: "terminal.tab.")
    XCTAssertTrue(
      tabs.firstMatch.waitForExistence(timeout: 5),
      "selecting a workroom should open a terminal tab")
    let initial = tabs.count

    app.typeKey("t", modifierFlags: .command)  // ⌘T → New Terminal
    assertCount(tabs, reaches: initial + 1)

    app.typeKey("w", modifierFlags: .command)  // ⌘W → Close Terminal
    assertCount(tabs, reaches: initial)
  }
}
