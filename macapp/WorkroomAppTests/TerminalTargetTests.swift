import XCTest

@testable import Workroom

final class TerminalTargetTests: XCTestCase {

  func testWorkroomTargetIDsAreDistinctAcrossProjects() {
    // The latent bug this fixes: two same-named workrooms in different projects must NOT
    // share a terminal/log. Project-scoped ids guarantee distinct keys.
    let a = Workroom(name: "sunny", path: "/wr/a/sunny", vcsName: "workroom/sunny", warnings: [])
    let b = Workroom(name: "sunny", path: "/wr/b/sunny", vcsName: "workroom/sunny", warnings: [])
    XCTAssertNotEqual(a.target(inProject: "/proj-a").id, b.target(inProject: "/proj-b").id)
    XCTAssertEqual(a.target(inProject: "/proj-a").id, "wr|/proj-a|sunny")
  }

  func testRootTargetID() {
    let p = Project(path: "/proj-a", vcs: "git", workrooms: [])
    XCTAssertEqual(p.rootTarget.id, "root|/proj-a")
    XCTAssertNotEqual(p.rootTarget.id, "wr|/proj-a|sunny")
  }

  func testWorkroomMissingFlagFromBlockingWarning() {
    let wr = Workroom(
      name: "x", path: "/nope", vcsName: "workroom/x",
      warnings: [Warning(kind: "DirectoryMissing", message: "gone", path: "/nope", vcs: nil)])
    XCTAssertTrue(wr.target(inProject: "/proj-a").isMissing)
  }

  func testRootMissingForNonexistentPath() {
    let p = Project(path: "/definitely/not/a/real/path/zzz", vcs: "git", workrooms: [])
    XCTAssertTrue(p.rootTarget.isMissing)
  }
}
