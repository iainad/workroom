import XCTest

/// UI test for the jj Changes panel's two collapsible groups — Working Copy (`@`) and Parent Commit
/// (`@-`). Fixture mode auto-selects the jj fixture workroom (`UITestFixture.workroomStatus`: a
/// working copy with changed files and a `.changes` parent with its own files), so the Changes
/// section renders both groups.
///
/// The git flat-list path ("must NOT enter jj two-group mode") is covered structurally rather than
/// here: `ChangesPanel` reaches `gitContent` only when `status.jjWorkingCopy == nil`, and the
/// resolver never sets that for git (see `WorkroomStatusResolverTests`/`WorkroomStatusIntegrationTests`).
///
/// Run with `make app-uitest` on a real GUI login session — XCUITest can't drive a headless run, so
/// this is excluded from `make app-test` (the unit gate) via a separate scheme.
final class ChangesPanelUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func launchedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-WorkroomUITestFixture", "1"]
    app.launch()
    app.activate()
    return app
  }

  /// A disclosure-group header by its accessibility id (the id sits on the header button, so a click
  /// toggles the group rather than hitting a file row inside an expanded body).
  private func group(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }

  /// A changed-file row, matched by its filename appearing in the row's composed a11y label.
  private func fileRow(_ app: XCUIApplication, _ name: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
  }

  /// Wait until `el` reaches the wanted existence state (tolerates the disclosure animation).
  @discardableResult
  private func waitExists(_ el: XCUIElement, _ want: Bool, _ timeout: TimeInterval = 4) -> Bool {
    let p = NSPredicate(format: "exists == %@", NSNumber(value: want))
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// Wait until `el`'s accessibility label contains `text`. The group header's label carries its
  /// "expanded"/"collapsed" state, so this asserts the toggle directly — robust to a long file list
  /// scrolling individual rows out of the inspector's a11y tree.
  @discardableResult
  private func waitLabel(_ el: XCUIElement, contains text: String, _ timeout: TimeInterval = 4)
    -> Bool
  {
    let p = NSPredicate(format: "label CONTAINS %@", text)
    return XCTWaiter().wait(
      for: [XCTNSPredicateExpectation(predicate: p, object: el)], timeout: timeout) == .completed
  }

  /// The jj Changes panel renders two groups, each headed by its change-id/commit/description and a
  /// changed-file count, with the working copy expanded and the parent collapsed by default — and the
  /// expanded group shows its file rows while the collapsed one hides them.
  func testWorkingCopyAndParentGroupsRenderWithCountsAndDefaultCollapse() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    XCTAssertTrue(
      group(app, "inspector.header.Changes").waitForExistence(timeout: 10),
      "Changes section should exist")

    let workingCopy = group(app, "changes.group.workingCopy")
    let parentCommit = group(app, "changes.group.parentCommit")
    XCTAssertTrue(workingCopy.waitForExistence(timeout: 10), "Working Copy group should render")
    XCTAssertTrue(parentCommit.waitForExistence(timeout: 10), "Parent Commit group should render")

    // Each header carries a changed-file count (the headline requirement) — 6 for the fixture working
    // copy, 3 for its parent — plus the default collapse state (working copy expanded, parent collapsed).
    XCTAssertTrue(waitLabel(workingCopy, contains: "expanded"), "Working Copy expanded by default")
    XCTAssertTrue(
      waitLabel(workingCopy, contains: "6 changed files"), "Working Copy header shows its count")
    XCTAssertTrue(
      waitLabel(parentCommit, contains: "collapsed"), "Parent Commit collapsed by default")
    XCTAssertTrue(
      waitLabel(parentCommit, contains: "3 changed files"), "Parent Commit header shows its count")

    // The expanded working copy renders its file rows; the collapsed parent hides its own.
    XCTAssertTrue(
      waitExists(fileRow(app, "Gemfile"), true), "expanded Working Copy renders its file rows")
    XCTAssertTrue(
      waitExists(fileRow(app, "auth_service.rb"), false),
      "collapsed Parent Commit hides its file rows")
  }

  /// Clicking a group header toggles it — the regression behind "header click does nothing": the
  /// collapse state must live on the observed store (`@Published`), not `@Default` in the panel, or
  /// the click writes the flag but the inspector body never re-renders.
  func testClickingHeaderTogglesGroup() throws {
    let app = launchedApp()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    let workingCopy = group(app, "changes.group.workingCopy")
    let parentCommit = group(app, "changes.group.parentCommit")
    XCTAssertTrue(workingCopy.waitForExistence(timeout: 10), "Working Copy group should render")

    // Collapse the working copy (its header sits at the top, so it's always hittable). Its files
    // disappear, which also frees the space that otherwise pushes the parent header below the fold.
    workingCopy.click()
    XCTAssertTrue(waitLabel(workingCopy, contains: "collapsed"), "click collapses Working Copy")
    XCTAssertTrue(
      waitExists(fileRow(app, "Gemfile"), false), "collapsing Working Copy hides its files")

    // With the working copy collapsed the parent header is in view → expanding it flips its state
    // and reveals its files.
    parentCommit.click()
    XCTAssertTrue(waitLabel(parentCommit, contains: "expanded"), "click expands Parent Commit")
    XCTAssertTrue(
      waitExists(fileRow(app, "auth_service.rb"), true), "expanding Parent Commit reveals its files"
    )
  }
}
