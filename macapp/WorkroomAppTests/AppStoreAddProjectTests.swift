import Foundation
import XCTest

@testable import Workroom

/// A fake CLI for unit-testing AppStore mutations without a real subprocess
/// (issue #103, the WorkroomCLIProtocol seam). Records add-project calls and lists
/// a controlled project set so post-add selection can be asserted.
final class FakeWorkroomCLI: WorkroomCLIProtocol {
  private(set) var addProjectCalls: [(path: String, create: Bool)] = []
  var canonicalToReturn: String
  var projectsToList: [Project]

  init(canonical: String, projects: [Project]) {
    self.canonicalToReturn = canonical
    self.projectsToList = projects
  }

  func list(warnings: String, project: String?) async throws -> ListResponse {
    ListResponse(projects: projectsToList, workroomsDir: nil, configPath: nil)
  }

  func addProject(_ path: String, create: Bool) async throws -> String {
    addProjectCalls.append((path, create))
    return canonicalToReturn
  }

  func create(
    project: String,
    onLog: ((String) -> Void)?,
    onReady: ((String, String, Bool) -> Void)?
  ) async throws -> CreateResponse {
    throw WorkroomCLIError.timedOut  // not exercised by these tests
  }

  func delete(name: String, project: String, onLog: ((String) -> Void)?) async throws {}

  func deleteProject(
    _ path: String, withWorkrooms: Bool, fromDisk: Bool, onLog: ((String) -> Void)?
  ) async throws -> [URL] { [] }
}

@MainActor
final class AppStoreAddProjectTests: XCTestCase {

  private func makeStore(_ fake: FakeWorkroomCLI) -> AppStore {
    let store = AppStore(cli: fake)
    store.terminals.makeView = { _, cwd, _ in GhosttySurfaceView(workingDirectory: cwd) }
    return store
  }

  /// Create mode passes --create and selects the project by the CANONICAL path the
  /// CLI returned — not the (possibly ~/symlinked) path the user typed.
  func testCreateModePassesFlagAndSelectsByCanonicalPath() async {
    let canonical = "/private/var/tmp/wr-new-project"
    let fake = FakeWorkroomCLI(
      canonical: canonical,
      projects: [Project(path: canonical, vcs: "git", workrooms: [])])
    let store = makeStore(fake)

    await store.addProject("~/typed/path", create: true)

    XCTAssertEqual(fake.addProjectCalls.count, 1)
    XCTAssertEqual(fake.addProjectCalls.first?.path, "~/typed/path")
    XCTAssertEqual(fake.addProjectCalls.first?.create, true)
    XCTAssertEqual(store.selectedProjectID, canonical, "should select by the CLI's canonical path")
    XCTAssertEqual(store.selectedTargetID, .root(project: canonical))
  }

  /// Existing mode passes create:false (preserving the repo-only path).
  func testExistingModePassesCreateFalse() async {
    let canonical = "/private/var/tmp/wr-existing-repo"
    let fake = FakeWorkroomCLI(
      canonical: canonical,
      projects: [Project(path: canonical, vcs: "git", workrooms: [])])
    let store = makeStore(fake)

    await store.addProject(canonical, create: false)

    XCTAssertEqual(fake.addProjectCalls.first?.create, false)
    XCTAssertEqual(store.selectedProjectID, canonical)
  }
}
