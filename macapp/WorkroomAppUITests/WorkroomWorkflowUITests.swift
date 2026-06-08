import XCTest

/// App-shell workflow UI tests (XCUITest). These drive Workroom through the accessibility tree —
/// sidebar, tabs, menus, badges. They do NOT assert on terminal *content*: the libghostty surface
/// is Metal-rendered and its text isn't in the a11y tree until CMT-3 lands (then content-level
/// assertions become possible — see TODOS.md).
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run,
/// so these are intentionally excluded from `make app-test` (the unit gate) via a separate scheme.
///
/// Workflow tests that need a project/workroom launch in **UI-test fixture mode**
/// (`-WorkroomUITestFixture 1`, see `UITestFixture`): the app loads fake projects/workrooms rooted at
/// a temp directory instead of the developer's real `~/.config/workroom`, and auto-selects the
/// fixture workroom — so they're deterministic and never depend on local config. The chrome smoke
/// test deliberately launches *without* the fixture, to prove the real bootstrap path renders chrome.
///
/// Still to add: notification badge + click-to-navigate (type `printf '\e]9;…\a'` → assert
/// sidebar/tab badge → click → navigates) and delete-workroom-clears-badges.
final class WorkroomWorkflowUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// Launch with the deterministic UI-test fixture (fake projects, auto-selected workroom). Fixture
  /// mode also suppresses the close/quit confirmations in-app, so ⌘W closes synchronously and teardown
  /// never blocks. Pass `fixture: false` to exercise the real bootstrap path (no fake projects).
  private func launchedApp(fixture: Bool = true) -> XCUIApplication {
    let app = XCUIApplication()
    if fixture { app.launchArguments += ["-WorkroomUITestFixture", "1"] }
    app.launch()
    return app
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

  /// Regression: expanding/collapsing a project must commit on the click itself, not only after the
  /// pointer leaves the row. The collapse state lived in a `@Default`, which didn't re-evaluate the
  /// sidebar until some other state changed (e.g. `hovered` on mouse-move) — so the tree appeared to
  /// "stick" until you moved the mouse. Moving it to the store's `@Published` fixed it. This test
  /// keeps the cursor parked on the project row across the toggle (never moving it) and asserts the
  /// child rows appear/disappear anyway.
  func testExpandCollapseCommitsWithoutMouseMove() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let project = app.descendants(matching: .any)
      .matching(identifier: "sidebar.project.UITestProject").firstMatch
    let workroom = app.descendants(matching: .any)
      .matching(identifier: "sidebar.workroom.uitest-room").firstMatch
    XCTAssertTrue(workroom.waitForExistence(timeout: 10), "fixture project starts expanded")

    // Wait for an existence state by re-snapshotting (which never moves the cursor), so the assertion
    // tolerates the reveal animation while still failing if the change waits for a pointer move.
    func waitExists(_ want: Bool) -> Bool {
      let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
      return XCTWaiter().wait(
        for: [XCTNSPredicateExpectation(predicate: p, object: workroom)], timeout: 3) == .completed
    }

    // Collapse: clicking parks the cursor on the row and leaves it there. The child must vanish
    // without any further pointer movement.
    project.click()
    XCTAssertTrue(
      waitExists(false),
      "collapse should commit on click, not wait for the pointer to leave the row")

    // Expand: same — the child must reappear with the cursor still parked on the row.
    project.click()
    XCTAssertTrue(
      waitExists(true),
      "expand should commit on click, not wait for the pointer to leave the row")
  }

  /// Deterministic smoke: the *real* bootstrap path (no fixture) launches and the shell chrome is
  /// present. The Add Project control lives in the sidebar's bottom bar regardless of config, so this
  /// has no dependency on the developer's projects.
  func testAppLaunchesWithChrome() {
    let app = launchedApp(fixture: false)
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "app did not reach foreground")
    XCTAssertGreaterThan(app.windows.count, 0, "expected a main window")
    XCTAssertTrue(
      app.descendants(matching: .any)["AddProject"].waitForExistence(timeout: 5),
      "the Add Project control should always be present in the sidebar")
  }

  /// The fixture workroom is auto-selected on launch, so a terminal tab is already open; ⌘T / ⌘W add
  /// and close tabs. Deterministic via the fixture — no sidebar navigation, no skip.
  func testAddAndCloseTerminalTabs() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    // Count title StaticTexts only — a chip's title and its close button both carry the
    // `terminal.tab.<title>` identifier, so matching `.any` would double-count each tab.
    let tabs = app.staticTexts.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "terminal.tab."))
    XCTAssertTrue(
      tabs.firstMatch.waitForExistence(timeout: 10),
      "the fixture workroom should open a terminal tab on launch")
    let initial = tabs.count

    app.typeKey("t", modifierFlags: .command)  // ⌘T → New Terminal
    assertCount(tabs, reaches: initial + 1)

    app.typeKey("w", modifierFlags: .command)  // ⌘W → Close Terminal
    assertCount(tabs, reaches: initial)
  }
}
