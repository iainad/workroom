import XCTest

@testable import Workroom

/// Project-deletion tests (issue #61). These drive the SAFE, synchronous seams only —
/// `removeProjectLocally` (optimistic in-memory cleanup), `SidebarID.belongsToProject`, and the
/// pure `DeleteProjectSheetModel`. The background CLI/config path (`deleteProject` → the bundled
/// `workroom` binary → the real ~/.config/workroom/config.json) is deliberately NOT exercised
/// here — it is covered by manual QA so the test suite never touches real projects or config.
@MainActor
final class AppStoreDeleteProjectTests: XCTestCase {

  private func makeStore(_ projects: [Project]) -> AppStore {
    let store = AppStore()
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
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

  // MARK: removeProjectLocally

  func testRemoveProjectLocallyDropsProjectAndReturnsAllTargets() {
    let p = project("/a", workrooms: ["feat", "bug"])
    let store = makeStore([p, project("/b", workrooms: ["x"])])

    let targets = store.removeProjectLocally(p)

    XCTAssertFalse(store.projects.contains { $0.id == "/a" }, "project not removed")
    XCTAssertTrue(store.projects.contains { $0.id == "/b" }, "unrelated project disturbed")
    XCTAssertEqual(
      Set(targets),
      [
        TerminalTarget.rootID(project: "/a"),
        TerminalTarget.workroomID(project: "/a", name: "feat"),
        TerminalTarget.workroomID(project: "/a", name: "bug"),
      ], "should return the root + every workroom target id")
  }

  func testRemoveProjectLocallyClearsSelectionInsideProject() {
    let p = project("/a", workrooms: ["feat"])
    let store = makeStore([p])
    store.selectedProjectID = "/a"
    store.selectedTargetID = .workroom(project: "/a", name: "feat")

    store.removeProjectLocally(p)

    XCTAssertNil(store.selectedTargetID, "selection inside the deleted project must clear")
    XCTAssertNil(store.selectedProjectID, "selected project must clear")
  }

  func testRemoveProjectLocallyPreservesSelectionInOtherProject() {
    let p = project("/a", workrooms: ["feat"])
    let other = project("/b", workrooms: ["x"])
    let store = makeStore([p, other])
    store.selectedProjectID = "/b"
    store.selectedTargetID = .root(project: "/b")

    store.removeProjectLocally(p)

    XCTAssertEqual(
      store.selectedTargetID, .root(project: "/b"), "other project's selection must survive")
    XCTAssertEqual(store.selectedProjectID, "/b")
  }

  func testRemoveProjectLocallyDropsStatuses() {
    let p = project("/a", workrooms: ["feat"])
    let store = makeStore([p])
    store.workroomStatuses[.root(project: "/a")] = .unresolved
    store.workroomStatuses[.workroom(project: "/a", name: "feat")] = .unresolved

    store.removeProjectLocally(p)

    XCTAssertNil(store.workroomStatuses[.root(project: "/a")], "root status must drop")
    XCTAssertNil(
      store.workroomStatuses[.workroom(project: "/a", name: "feat")], "workroom status must drop")
  }

  // MARK: SidebarID.belongsToProject

  func testSidebarIDBelongsToProject() {
    XCTAssertTrue(SidebarID.root(project: "/a").belongsToProject("/a"))
    XCTAssertTrue(SidebarID.workroom(project: "/a", name: "feat").belongsToProject("/a"))
    XCTAssertTrue(SidebarID.project("/a").belongsToProject("/a"))
    XCTAssertFalse(SidebarID.root(project: "/b").belongsToProject("/a"))
    XCTAssertFalse(SidebarID.workroom(project: "/b", name: "feat").belongsToProject("/a"))
  }

  // MARK: DeleteProjectSheetModel (pure presentation rules)

  func testSheetNameMatchIsExact() {
    XCTAssertTrue(DeleteProjectSheetModel.nameMatches(typed: "app", displayName: "app"))
    XCTAssertFalse(DeleteProjectSheetModel.nameMatches(typed: "App", displayName: "app"))
    XCTAssertFalse(DeleteProjectSheetModel.nameMatches(typed: " app ", displayName: "app"))
    XCTAssertFalse(DeleteProjectSheetModel.nameMatches(typed: "", displayName: "app"))
  }

  func testSheetDeleteLabelEscalatesWithCascade() {
    XCTAssertEqual(
      DeleteProjectSheetModel.deleteLabel(workroomCount: 3, cascade: false), "Delete Project")
    XCTAssertEqual(
      DeleteProjectSheetModel.deleteLabel(workroomCount: 3, cascade: true),
      "Delete Project & 3 Workrooms")
    XCTAssertEqual(
      DeleteProjectSheetModel.deleteLabel(workroomCount: 1, cascade: true),
      "Delete Project & 1 Workroom", "singular workroom")
  }

  func testSheetEffectFooterReflectsToggle() {
    XCTAssertTrue(
      DeleteProjectSheetModel.effectFooter(workroomCount: 2, cascade: false)
        .contains("Worktrees, branches, and files on disk are kept"))
    let warned = DeleteProjectSheetModel.effectFooter(workroomCount: 2, cascade: true)
    XCTAssertTrue(warned.contains("Permanently deletes 2 worktree directories"))
    XCTAssertTrue(
      warned.contains("Branches are kept"), "cascade footer must still promise branches survive")
  }
}
