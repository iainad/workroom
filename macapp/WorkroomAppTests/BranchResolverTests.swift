import XCTest

@testable import Workroom

/// A `CommandRunning` that returns canned output per (executable, args), so BranchResolver
/// can be tested without spawning real git/jj.
private struct MockRunner: CommandRunning {
  let handler: @Sendable (_ executable: String, _ args: [String]) -> String?
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> String?
  {
    handler(executable, args)
  }
}

final class BranchResolverTests: XCTestCase {

  // MARK: git

  func testGitOnBranch() async {
    let r = BranchResolver(
      runner: MockRunner { _, args in
        args.contains("symbolic-ref") ? "main" : nil
      })
    let ref = await r.resolve(path: "/x", vcs: "git")
    XCTAssertEqual(ref.kind, .branch)
    XCTAssertEqual(ref.branch, "main")
  }

  func testGitUnbornRepoIsStillBranch() async {
    // `git symbolic-ref` succeeds on an unborn repo (HEAD → refs/heads/main before the
    // first commit), so the working copy is "on" main — NOT .none.
    let r = BranchResolver(
      runner: MockRunner { _, args in
        args.contains("symbolic-ref") ? "main" : nil
      })
    let ref = await r.resolve(path: "/x", vcs: "git")
    XCTAssertEqual(ref.kind, .branch)
  }

  func testGitDetached() async {
    let r = BranchResolver(
      runner: MockRunner { _, args in
        if args.contains("symbolic-ref") { return nil }  // detached → fails
        if args.contains("rev-parse") { return "a1b2c3d" }
        return nil
      })
    let ref = await r.resolve(path: "/x", vcs: "git")
    XCTAssertEqual(ref.kind, .detached)
    XCTAssertEqual(ref.branch, "a1b2c3d")
  }

  func testGitNone() async {
    let r = BranchResolver(runner: MockRunner { _, _ in nil })
    let ref = await r.resolve(path: "/x", vcs: "git")
    XCTAssertEqual(ref.kind, .none)
    XCTAssertNil(ref.branch)
  }

  // MARK: jj
  // First query is `-r @`; the fallback is `-r heads(::@ & bookmarks())`.

  func testJJBookmarkOnWorkingCopy() async {
    let r = BranchResolver(
      runner: MockRunner { _, args in
        args.contains("@") ? "feature" : nil
      })
    let ref = await r.resolve(path: "/x", vcs: "jj")
    XCTAssertEqual(ref.kind, .branch)
    XCTAssertEqual(ref.branch, "feature")
  }

  func testJJAncestorFallback() async {
    let r = BranchResolver(
      runner: MockRunner { _, args in
        if args.contains("@") { return "" }  // no bookmark on @
        if args.contains("heads(::@ & bookmarks())") { return "master\n" }
        return nil
      })
    let ref = await r.resolve(path: "/x", vcs: "jj")
    XCTAssertEqual(ref.kind, .ancestor)
    XCTAssertEqual(ref.branch, "master")
  }

  func testJJNoBookmarksAnywhere() async {
    let r = BranchResolver(runner: MockRunner { _, _ in "" })
    let ref = await r.resolve(path: "/x", vcs: "jj")
    XCTAssertEqual(ref.kind, .none)
  }

  func testJJMultipleBookmarksTakesFirst() async {
    let r = BranchResolver(
      runner: MockRunner { _, args in
        args.contains("@") ? "feat-a feat-b" : nil
      })
    let ref = await r.resolve(path: "/x", vcs: "jj")
    XCTAssertEqual(ref.branch, "feat-a")
  }

  func testUnknownVCS() async {
    let r = BranchResolver(runner: MockRunner { _, _ in "anything" })
    let ref = await r.resolve(path: "/x", vcs: "hg")
    XCTAssertEqual(ref.kind, .none)
  }

  // MARK: firstBookmark normalization (Codex #9)

  func testFirstBookmarkNormalization() {
    XCTAssertEqual(BranchResolver.firstBookmark("main"), "main")
    XCTAssertEqual(BranchResolver.firstBookmark("main*"), "main")  // conflicted
    XCTAssertEqual(BranchResolver.firstBookmark("main??"), "main")  // conflicted
    XCTAssertEqual(BranchResolver.firstBookmark("main@origin"), "main")  // remote-tracking
    XCTAssertEqual(BranchResolver.firstBookmark("feat-a feat-b"), "feat-a")
    XCTAssertEqual(BranchResolver.firstBookmark("\n\nmaster\n"), "master")
    XCTAssertNil(BranchResolver.firstBookmark(""))
    XCTAssertNil(BranchResolver.firstBookmark("   \n  "))
  }
}
