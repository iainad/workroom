import XCTest

/// XCUITest smoke for the always-present workroom tab bar (issue #23): a workroom that has a terminal
/// shows a tab above the terminal area. Driven through the accessibility tree in UI-test fixture mode
/// (`-WorkroomUITestFixture 1`), which auto-selects a workroom and opens a terminal in it. The drag
/// gesture isn't observable from XCUITest; that's manual QA.
final class WorkroomsViewUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launch()
    app.activate()
    return app
  }

  /// The fixture auto-selects a workroom and opens a terminal in it, so its workroom tab appears in the
  /// always-present tab bar above the terminal.
  func testActiveWorkroomShowsATab() {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    let tab = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "workroom.tab.")).firstMatch
    XCTAssertTrue(
      tab.waitForExistence(timeout: 10),
      "a workroom with a terminal should show a tab in the always-present tab bar")
  }
}
