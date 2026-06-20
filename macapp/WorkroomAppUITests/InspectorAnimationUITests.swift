import XCTest

/// UI smoke test for the right inspector's section layout (issue #24), now composed as a raw
/// `NSSplitView` (see `InspectorSplitView`). Collapsing a section pins it to its header and
/// redistributes the freed space among the still-expanded sections, so a lower header moves up;
/// expanding it again moves the header back down. This replaces the earlier "title swim" animation
/// reproduction — the swim is gone by construction now that each header is its own stable hosting
/// view and collapse moves sibling *panes* (not a per-frame SwiftUI re-layout of a translating
/// `Text`), so there is no animated translation left to glitch.
///
/// XCUITest sees accessibility *geometry* (layout frames), which is exactly what this asserts: the
/// Pull Request header's vertical position before/after collapsing Changes.
final class InspectorAnimationUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-WorkroomUITestFixture", "1",
      "-WorkroomUITestManyChanges", "1",
      // Start each test clean, ignoring persisted window state (cf. NewWindowUITests).
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    app.activate()
    return app
  }

  private func header(_ app: XCUIApplication, _ title: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(identifier: "inspector.header.\(title)").firstMatch
  }

  func testCollapsingChangesMovesLowerHeaderUpAndBack() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let changes = header(app, "Changes")
    let pr = header(app, "Pull Request")
    XCTAssertTrue(changes.waitForExistence(timeout: 10), "Changes header should exist")
    XCTAssertTrue(pr.waitForExistence(timeout: 10), "Pull Request header should exist")

    let expandedY = pr.frame.minY

    // Collapse the (tall) Changes section: it pins to its header, so the Pull Request header rises.
    changes.click()
    let collapsedY = pr.frame.minY
    XCTAssertLessThan(
      collapsedY, expandedY, "collapsing Changes should move the Pull Request header up")

    // Expand it again: the equal distribution returns and the header drops back to ~where it was.
    changes.click()
    XCTAssertEqual(
      pr.frame.minY, expandedY, accuracy: 2,
      "re-expanding Changes should restore the Pull Request header position")
  }
}
