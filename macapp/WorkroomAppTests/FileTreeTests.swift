import XCTest

@testable import Workroom

/// Unit tests for the pure, engine-free core of the Files inspector section (`FileTree.swift`,
/// `FileHighlightMapper`, and the `PlainFileViewer` read gating). Everything past these needs a live
/// repo / view and is covered by manual QA.
final class FileTreeTests: XCTestCase {

  // MARK: FileTreeBuilder.build

  func testBuildNestsAndSortsDirsBeforeFiles() {
    let roots = FileTreeBuilder.build(from: [
      "b/y.txt", "b/x.txt", "a.txt", "b/sub/z.txt",
    ])
    // Top level: directory "b" before file "a.txt".
    XCTAssertEqual(roots.map(\.name), ["b", "a.txt"])
    XCTAssertTrue(roots[0].isDirectory)
    XCTAssertNotNil(roots[0].children)  // directory has children
    XCTAssertFalse(roots[1].isDirectory)
    XCTAssertNil(roots[1].children)  // file leaf

    // Inside "b": directory "sub" first, then files alphabetically.
    XCTAssertEqual(roots[0].children?.map(\.name), ["sub", "x.txt", "y.txt"])
    let sub = roots[0].children?.first
    XCTAssertEqual(sub?.name, "sub")
    XCTAssertTrue(sub?.isDirectory == true)
    XCTAssertEqual(sub?.children?.map(\.path), ["b/sub/z.txt"])
    XCTAssertEqual(sub?.children?.first?.name, "z.txt")
  }

  func testBuildDedupesIntermediateDirectories() {
    let roots = FileTreeBuilder.build(from: ["src/a.swift", "src/b.swift"])
    XCTAssertEqual(roots.count, 1)
    XCTAssertEqual(roots.first?.name, "src")
    XCTAssertEqual(roots.first?.children?.map(\.name), ["a.swift", "b.swift"])
  }

  func testBuildSkipsEmptyAndDotComponentsAndLeadingDotSlash() {
    let roots = FileTreeBuilder.build(from: ["./a.txt", "", "b//c.txt"])
    XCTAssertEqual(roots.map(\.name), ["b", "a.txt"])
    XCTAssertEqual(roots.first { $0.name == "b" }?.children?.map(\.path), ["b/c.txt"])
  }

  func testBuildEmptyInput() {
    XCTAssertTrue(FileTreeBuilder.build(from: []).isEmpty)
  }

  // MARK: FileTreeBuilder.flatten

  func testFlattenRespectsExpansionAndDepth() {
    let roots = FileTreeBuilder.build(from: ["b/sub/z.txt", "b/x.txt", "a.txt"])

    let collapsed = FileTreeBuilder.flatten(roots, expanded: [])
    XCTAssertEqual(collapsed.map { "\($0.node.name)@\($0.depth)" }, ["b@0", "a.txt@0"])

    let bOpen = FileTreeBuilder.flatten(roots, expanded: ["b"])
    XCTAssertEqual(
      bOpen.map { "\($0.node.name)@\($0.depth)" }, ["b@0", "sub@1", "x.txt@1", "a.txt@0"])

    let allOpen = FileTreeBuilder.flatten(roots, expanded: ["b", "b/sub"])
    XCTAssertEqual(
      allOpen.map { "\($0.node.name)@\($0.depth)" },
      ["b@0", "sub@1", "z.txt@2", "x.txt@1", "a.txt@0"])
  }

  // MARK: FileListing

  func testListCommands() {
    XCTAssertEqual(FileListing.command(.git).executable, "git")
    XCTAssertEqual(
      FileListing.command(.git).args,
      ["ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    XCTAssertEqual(FileListing.command(.jj).executable, "jj")
    XCTAssertEqual(FileListing.command(.jj).args, ["file", "list"])
  }

  func testGitParseSplitsOnNulAndPreservesSpaces() {
    let stdout = "a.txt\u{0}b c.txt\u{0}\u{0}sub/d.txt\u{0}"
    XCTAssertEqual(FileListing.parse(stdout, vcs: .git), ["a.txt", "b c.txt", "sub/d.txt"])
  }

  func testJJParseSplitsOnNewlineTrimsCRAndStripsDotSlash() {
    XCTAssertEqual(
      FileListing.parse("a.txt\n./sub/d.txt\n\n", vcs: .jj), ["a.txt", "sub/d.txt"])
    XCTAssertEqual(FileListing.parse("x.txt\r\n", vcs: .jj), ["x.txt"])
  }

  // MARK: FileTreeModel.list (git → jj fallthrough)

  func testListPrefersGitWhenAvailable() async {
    let runner = StubRunner(byExecutable: [
      "git": CommandResult(stdout: "a.txt\u{0}b.txt\u{0}", stderr: "", exitCode: 0, timedOut: false)
    ])
    let paths = await FileTreeModel.list(path: "/repo", runner: runner)
    XCTAssertEqual(paths, ["a.txt", "b.txt"])
  }

  func testListFallsThroughToJJWhenGitFails() async {
    let runner = StubRunner(byExecutable: [
      "git": CommandResult(stdout: "", stderr: "not a repo", exitCode: 128, timedOut: false),
      "jj": CommandResult(stdout: "x.txt\ny.txt\n", stderr: "", exitCode: 0, timedOut: false),
    ])
    let paths = await FileTreeModel.list(path: "/repo", runner: runner)
    XCTAssertEqual(paths, ["x.txt", "y.txt"])
  }

  func testListReturnsNilWhenNeitherVCSResponds() async {
    let runner = StubRunner(byExecutable: [:])  // every command → not-found
    let paths = await FileTreeModel.list(path: "/repo", runner: runner)
    XCTAssertNil(paths)
  }

  // MARK: PlainFileViewer.classify (read gating)

  func testClassifyEmpty() {
    XCTAssertEqual(PlainFileViewer.classify(data: Data()), .empty)
  }

  func testClassifyTooLarge() {
    XCTAssertEqual(PlainFileViewer.classify(data: Data(count: 100), byteCap: 10), .tooLarge)
  }

  func testClassifyBinaryFromNulByte() {
    XCTAssertEqual(PlainFileViewer.classify(data: Data([0x41, 0x00, 0x42])), .binary)
  }

  func testClassifyBinaryFromInvalidUTF8() {
    // 0xFF/0xFE are not valid UTF-8 and contain no NUL → still binary (decode fails).
    XCTAssertEqual(PlainFileViewer.classify(data: Data([0xFF, 0xFE, 0x41])), .binary)
  }

  func testClassifyText() {
    let data = Data("let x = 1\n".utf8)
    XCTAssertEqual(PlainFileViewer.classify(data: data), .text("let x = 1\n"))
  }

  // MARK: PlainFileViewer.splitLines

  func testSplitLinesDropsTrailingNewlinePhantom() {
    XCTAssertEqual(PlainFileViewer.splitLines("a\nb\n"), ["a", "b"])
    XCTAssertEqual(PlainFileViewer.splitLines("a\nb"), ["a", "b"])
    XCTAssertEqual(PlainFileViewer.splitLines("a\n"), ["a"])
    XCTAssertEqual(PlainFileViewer.splitLines(""), [""])
  }

  // MARK: FileHighlightMapper (line bucketing)

  @MainActor func testHighlightMapperLineCountAndPlainTextWithoutSpans() {
    let tokens = ThemeService.shared.tokens
    let content = "let x = 1\nfoo"
    let lines = FileHighlightMapper.attributedLines(content: content, spans: [], tokens: tokens)
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(String(lines[0].characters), "let x = 1")
    XCTAssertEqual(String(lines[1].characters), "foo")
  }

  @MainActor func testHighlightMapperDropsTrailingNewlineLine() {
    let tokens = ThemeService.shared.tokens
    let lines = FileHighlightMapper.attributedLines(content: "a\n", spans: [], tokens: tokens)
    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(String(lines[0].characters), "a")
  }

  @MainActor func testHighlightMapperEmptyContent() {
    let tokens = ThemeService.shared.tokens
    XCTAssertTrue(
      FileHighlightMapper.attributedLines(content: "", spans: [], tokens: tokens).isEmpty)
  }
}

/// A canned `StatusCommandRunning` for the git→jj fallthrough tests: returns a per-executable result,
/// or a command-not-found (127) for anything unlisted.
private struct StubRunner: StatusCommandRunning {
  let byExecutable: [String: CommandResult]

  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> CommandResult
  {
    byExecutable[executable]
      ?? CommandResult(stdout: "", stderr: "", exitCode: 127, timedOut: false)
  }
}
