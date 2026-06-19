import XCTest

@testable import Workroom

/// Tests for `DiffResolver.fileContent` — the new-side content fetch that feeds syntax highlighting.
/// Working-copy sources read disk (exercised against a real temp workroom, never a real repo); the
/// jj parent shells out (exercised via a recording mock runner so we can assert the exact args —
/// crucially that it uses `@-` and never `-r @`).
final class DiffResolverFileContentTests: XCTestCase {

  // A runner that records calls and returns a canned result; also flags whether it was called at
  // all (disk-read sources must NOT touch it).
  private final class RecordingRunner: StatusCommandRunning, @unchecked Sendable {
    let result: CommandResult
    private let lock = NSLock()
    private var _calls: [(exe: String, args: [String])] = []
    var calls: [(exe: String, args: [String])] {
      lock.lock()
      defer { lock.unlock() }
      return _calls
    }
    init(result: CommandResult) { self.result = result }
    func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
      async -> CommandResult
    {
      lock.lock()
      _calls.append((executable, args))
      lock.unlock()
      return result
    }
  }

  private func ok(_ stdout: String) -> CommandResult {
    CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false)
  }

  /// A fresh temp workroom directory, auto-removed at test end.
  private func makeWorkroom() throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("workroom-fc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }

  private func desc(_ path: String, _ source: DiffSource, _ change: ChangedFile.Change = .modified)
    -> DiffDescriptor
  {
    DiffDescriptor(path: path, change: change, source: source, isPreview: false)
  }

  // MARK: - Pure command builder

  func testParentShowCommandUsesParentNotWorkingCopy() {
    let (exe, args) = DiffResolver.parentShowCommand(path: "app/models/user.rb")
    XCTAssertEqual(exe, "jj")
    XCTAssertEqual(
      args, ["file", "show", "-r", "@-", "--ignore-working-copy", "--", "app/models/user.rb"])
    XCTAssertTrue(args.contains("@-"), "must target the parent revision")
    XCTAssertFalse(args.contains("@"), "must never use -r @ (would take the working-copy lock)")
    XCTAssertTrue(args.contains("--ignore-working-copy"))
  }

  // MARK: - jj parent (shells out)

  func testJJParentReadsViaFileShow() async throws {
    let dir = try makeWorkroom()
    let runner = RecordingRunner(result: ok("class User\nend\n"))
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let content = await resolver.fileContent(for: desc("user.rb", .jjParent), in: dir.path)
    XCTAssertEqual(content, "class User\nend\n")
    let call = runner.calls.first
    XCTAssertEqual(call?.exe, "jj")
    XCTAssertEqual(call?.args.first, "file")
    XCTAssertTrue(call?.args.contains("@-") == true)
    XCTAssertFalse(call?.args.contains("@") == true, "must never pass -r @")
  }

  func testJJParentEmptyOutputIsNil() async throws {
    let dir = try makeWorkroom()
    let resolver = DiffResolver(runner: RecordingRunner(result: ok("")), timeout: 5)
    let content = await resolver.fileContent(for: desc("user.rb", .jjParent), in: dir.path)
    XCTAssertNil(content)
  }

  func testJJParentFailureIsNil() async throws {
    let dir = try makeWorkroom()
    let fail = CommandResult(stdout: "x", stderr: "no such path", exitCode: 1, timedOut: false)
    let resolver = DiffResolver(runner: RecordingRunner(result: fail), timeout: 5)
    let content = await resolver.fileContent(for: desc("user.rb", .jjParent), in: dir.path)
    XCTAssertNil(content)
  }

  func testJJParentOverCapIsNil() async throws {
    let dir = try makeWorkroom()
    let big = String(repeating: "a", count: SyntaxLanguage.byteCap + 1)
    let resolver = DiffResolver(runner: RecordingRunner(result: ok(big)), timeout: 5)
    let content = await resolver.fileContent(for: desc("big.rb", .jjParent), in: dir.path)
    XCTAssertNil(content, "content at/over the parse cap must render plain, not mis-map")
  }

  // MARK: - Working-copy sources (disk read; runner must NOT be called)

  func testGitWorktreeReadsDiskWithoutRunner() async throws {
    let dir = try makeWorkroom()
    let body = "func main() {}\n"
    try body.write(
      to: dir.appendingPathComponent("main.go"), atomically: true, encoding: .utf8)
    let runner = RecordingRunner(result: ok("SHOULD NOT BE USED"))
    let resolver = DiffResolver(runner: runner, timeout: 5)
    let content = await resolver.fileContent(for: desc("main.go", .gitWorktree), in: dir.path)
    XCTAssertEqual(content, body)
    XCTAssertTrue(runner.calls.isEmpty, "working-copy reads must not shell out")
  }

  func testJJWorkingCopyReadsDisk() async throws {
    let dir = try makeWorkroom()
    let body = "puts 'hi'\n"
    try body.write(to: dir.appendingPathComponent("a.rb"), atomically: true, encoding: .utf8)
    let resolver = DiffResolver(runner: RecordingRunner(result: ok("x")), timeout: 5)
    let content = await resolver.fileContent(for: desc("a.rb", .jjWorkingCopy), in: dir.path)
    XCTAssertEqual(content, body)
  }

  func testNestedPathReadsDisk() async throws {
    let dir = try makeWorkroom()
    let sub = dir.appendingPathComponent("app/models", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let body = "class User; end\n"
    try body.write(to: sub.appendingPathComponent("user.rb"), atomically: true, encoding: .utf8)
    let resolver = DiffResolver(runner: RecordingRunner(result: ok("x")), timeout: 5)
    let content = await resolver.fileContent(
      for: desc("app/models/user.rb", .gitWorktree), in: dir.path)
    XCTAssertEqual(content, body)
  }

  // MARK: - Guards

  func testMissingFileIsNil() async throws {
    let dir = try makeWorkroom()
    let resolver = DiffResolver(runner: RecordingRunner(result: ok("x")), timeout: 5)
    let content = await resolver.fileContent(for: desc("gone.swift", .gitWorktree), in: dir.path)
    XCTAssertNil(content)
  }

  func testSymlinkLeafIsNil() async throws {
    let dir = try makeWorkroom()
    // A real file outside the workroom, and a symlink inside pointing at it.
    let outside = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fc-target-\(UUID().uuidString).swift")
    try "let secret = 1\n".write(to: outside, atomically: true, encoding: .utf8)
    addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
    let link = dir.appendingPathComponent("link.swift")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    let resolver = DiffResolver(runner: RecordingRunner(result: ok("x")), timeout: 5)
    let content = await resolver.fileContent(for: desc("link.swift", .gitWorktree), in: dir.path)
    XCTAssertNil(content, "a symlink's diff is its target-path text, not file content → plain")
  }

  func testPathEscapingWorkroomIsNil() async throws {
    let dir = try makeWorkroom()
    let resolver = DiffResolver(runner: RecordingRunner(result: ok("x")), timeout: 5)
    let content = await resolver.fileContent(
      for: desc("../../../../etc/hosts", .gitWorktree), in: dir.path)
    XCTAssertNil(content, "a path escaping the workroom must not be read")
  }

  func testOverCapFileIsNil() async throws {
    let dir = try makeWorkroom()
    let big = String(repeating: "x", count: SyntaxLanguage.byteCap + 10)
    try big.write(to: dir.appendingPathComponent("big.json"), atomically: true, encoding: .utf8)
    let resolver = DiffResolver(runner: RecordingRunner(result: ok("x")), timeout: 5)
    let content = await resolver.fileContent(for: desc("big.json", .gitWorktree), in: dir.path)
    XCTAssertNil(content, "files over the byte cap must render plain")
  }
}
