import XCTest

@testable import Workroom

/// Covers the pure path classification/resolution behind ⌘-click-to-open. The actual launch
/// (`open`) and the kernel cwd lookup are side-effecting and out of scope here.
final class TerminalLinkOpenerTests: XCTestCase {

  // filePath(from:) — web URLs return nil (the caller opens them via NSWorkspace); else a path.

  func testWebURLsAreNotFilePaths() {
    for url in [
      "https://example.com/x", "http://a.b", "mailto:me@x.com", "ssh://host", "git://h/r",
    ] {
      XCTAssertNil(
        TerminalLinkOpener.filePath(from: url), "\(url) should pass through to the browser handler")
    }
  }

  func testFileURLBecomesPath() {
    XCTAssertEqual(TerminalLinkOpener.filePath(from: "file:///tmp/a.txt"), "/tmp/a.txt")
  }

  func testBarePathsAreFilePaths() {
    XCTAssertEqual(TerminalLinkOpener.filePath(from: "src/main.go"), "src/main.go")
    XCTAssertEqual(TerminalLinkOpener.filePath(from: "/etc/hosts"), "/etc/hosts")
    XCTAssertEqual(TerminalLinkOpener.filePath(from: "./rel.txt"), "./rel.txt")
  }

  // absolutePath(for:cwd:) — absolute stays put; ~ expands; relative joins the cwd.

  func testAbsolutePathUnchanged() {
    XCTAssertEqual(
      TerminalLinkOpener.absolutePath(for: "/etc/hosts", cwd: "/somewhere"), "/etc/hosts")
  }

  func testTildeExpands() {
    let home = NSHomeDirectory()
    XCTAssertEqual(TerminalLinkOpener.absolutePath(for: "~/x.txt", cwd: nil), "\(home)/x.txt")
  }

  func testRelativeJoinsCwd() {
    XCTAssertEqual(
      TerminalLinkOpener.absolutePath(for: "src/main.go", cwd: "/proj"), "/proj/src/main.go")
  }

  func testRelativeWithoutCwdIsNil() {
    // No working directory known → can't resolve a relative path.
    XCTAssertNil(TerminalLinkOpener.absolutePath(for: "src/main.go", cwd: nil))
  }

  // openArguments(path:editorBundleID:) — default app vs a chosen, installed editor.

  func testNoEditorUsesDefaultApp() {
    XCTAssertEqual(
      TerminalLinkOpener.openArguments(path: "/x.txt", editorBundleID: nil), ["/x.txt"])
    XCTAssertEqual(TerminalLinkOpener.openArguments(path: "/x.txt", editorBundleID: ""), ["/x.txt"])
  }

  func testInstalledEditorOpensWithBundleID() {
    // Finder is always installed, so it stands in for a chosen editor here.
    XCTAssertEqual(
      TerminalLinkOpener.openArguments(path: "/x.txt", editorBundleID: "com.apple.finder"),
      ["-b", "com.apple.finder", "/x.txt"]
    )
  }

  func testUninstalledEditorFallsBackToDefaultApp() {
    XCTAssertEqual(
      TerminalLinkOpener.openArguments(path: "/x.txt", editorBundleID: "com.example.nope"),
      ["/x.txt"]
    )
  }

  // pathCandidates(from:) — the literal is always probed first; then trailing-`.` and
  // `:line[:col]` decorations are stripped, with the parsed line/column carried (issue #34).

  private typealias Candidate = TerminalLinkOpener.PathCandidate

  func testPlainPathHasNoExtraCandidates() {
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.rb"),
      [Candidate(path: "./dev/file.rb", line: nil, column: nil)])
    // A double extension is just part of the name — not a decoration.
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.html.erb"),
      [Candidate(path: "./dev/file.html.erb", line: nil, column: nil)])
  }

  func testTrailingDotIsStrippedAfterTheLiteral() {
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "/Users/me/file.rb."),
      [
        Candidate(path: "/Users/me/file.rb.", line: nil, column: nil),
        Candidate(path: "/Users/me/file.rb", line: nil, column: nil),
      ])
  }

  func testLineSuffixIsStrippedAndCarried() {
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.html:12"),
      [
        Candidate(path: "./dev/file.html:12", line: nil, column: nil),
        Candidate(path: "./dev/file.html", line: 12, column: nil),
      ])
  }

  func testLineAndColumnAreCarried() {
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.html:12:5"),
      [
        Candidate(path: "./dev/file.html:12:5", line: nil, column: nil),
        Candidate(path: "./dev/file.html", line: 12, column: 5),
      ])
  }

  func testNonNumericColumnIsDroppedButLineKept() {
    // Rails-style file:line:in — the line number is kept; the non-numeric tail is decoration.
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "./dev/file.html:12:foo"),
      [
        Candidate(path: "./dev/file.html:12:foo", line: nil, column: nil),
        Candidate(path: "./dev/file.html", line: 12, column: nil),
      ])
  }

  func testColonNotFollowedByDigitIsKept() {
    // Only a ":<digit>" boundary is a line suffix; a bare colon stays part of the literal.
    XCTAssertEqual(
      TerminalLinkOpener.pathCandidates(from: "a:b/file.rb"),
      [Candidate(path: "a:b/file.rb", line: nil, column: nil)])
  }

  // launchInvocation(...) — line-aware editor dispatch. editorInstalled/zedCLIPath are injected so
  // the mapping is pure; the with-line branches don't touch Launch Services.

  func testVSCodeSeeksToLineViaURLScheme() {
    let withColumn = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: 5),
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true, zedCLIPath: nil)
    XCTAssertEqual(withColumn.executable, "/usr/bin/open")
    XCTAssertEqual(withColumn.arguments, ["vscode://file/proj/app.rb:12:5"])

    let lineOnly = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: nil),
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true, zedCLIPath: nil)
    XCTAssertEqual(lineOnly.arguments, ["vscode://file/proj/app.rb:12"])
  }

  func testZedSeeksToLineViaBundledCLI() {
    let cli = "/Applications/Zed.app/Contents/MacOS/cli"
    let inv = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: 5),
      editorBundleID: "dev.zed.Zed", editorInstalled: true, zedCLIPath: cli)
    XCTAssertEqual(inv.executable, cli)
    XCTAssertEqual(inv.arguments, ["/proj/app.rb:12:5"])
  }

  func testZedFallsBackToOpenWhenCLIMissing() {
    let inv = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: 5),
      editorBundleID: "dev.zed.Zed", editorInstalled: true, zedCLIPath: nil)
    // Opens at the top; the exact `-b` argv depends on whether Zed is installed in this environment.
    XCTAssertEqual(inv.executable, "/usr/bin/open")
    XCTAssertEqual(inv.arguments.last, "/proj/app.rb")
  }

  func testXcodeSeeksToLineViaXed() {
    let inv = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: 12, column: 5),
      editorBundleID: "com.apple.dt.Xcode", editorInstalled: true, zedCLIPath: nil)
    XCTAssertEqual(inv.executable, "/usr/bin/xed")
    XCTAssertEqual(inv.arguments, ["--line", "12", "/proj/app.rb"])  // no column option in xed
  }

  func testNoLineOpensViaOpenRegardlessOfEditor() {
    let inv = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/proj/app.rb", line: nil, column: nil),
      editorBundleID: "com.microsoft.VSCode", editorInstalled: true, zedCLIPath: nil)
    XCTAssertEqual(inv.executable, "/usr/bin/open")
    XCTAssertEqual(inv.arguments.last, "/proj/app.rb")
  }

  func testUninstalledOrUnknownEditorWithLineOpensInDefaultApp() {
    // Uninstalled chosen editor → default app (no -b), no line.
    let uninstalled = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/x.rb", line: 12, column: nil),
      editorBundleID: "com.example.nope", editorInstalled: false, zedCLIPath: nil)
    XCTAssertEqual(uninstalled.executable, "/usr/bin/open")
    XCTAssertEqual(uninstalled.arguments, ["/x.rb"])

    // An editor we don't know how to seek in → open it (here "nope" isn't installed → default app).
    let unknown = TerminalLinkOpener.launchInvocation(
      file: .init(path: "/x.rb", line: 12, column: nil),
      editorBundleID: "com.example.nope", editorInstalled: true, zedCLIPath: nil)
    XCTAssertEqual(unknown.arguments, ["/x.rb"])
  }

  // The pure URL/arg builders.

  func testVSCodeURLPercentEncodesPathKeepingSlashes() {
    XCTAssertEqual(
      TerminalLinkOpener.vscodeFileURL(path: "/proj/my app.rb", line: 7, column: nil),
      "vscode://file/proj/my%20app.rb:7")
    XCTAssertEqual(
      TerminalLinkOpener.vscodeFileURL(path: "/a/b.rb", line: 7, column: 3),
      "vscode://file/a/b.rb:7:3")
  }

  func testZedPositionArgument() {
    XCTAssertEqual(
      TerminalLinkOpener.zedPositionArgument(path: "/a/b.rb", line: 7, column: 3), "/a/b.rb:7:3")
    XCTAssertEqual(
      TerminalLinkOpener.zedPositionArgument(path: "/a/b.rb", line: 7, column: nil), "/a/b.rb:7")
  }

  // resolvesToFile(_:cwd:) — end-to-end against real files: every shape in issue #34 resolves.

  func testIssue34PathShapesAllResolve() throws {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nested = dir.appendingPathComponent("dev")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    for name in ["file.rb", "file.html", "file.html.erb"] {
      fm.createFile(atPath: nested.appendingPathComponent(name).path, contents: Data())
    }
    defer { try? fm.removeItem(at: dir) }
    let cwd = dir.path
    let absoluteRb = nested.appendingPathComponent("file.rb").path

    XCTAssertTrue(TerminalLinkOpener.resolvesToFile(absoluteRb, cwd: nil))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("\(absoluteRb).", cwd: nil))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("./dev/file.rb", cwd: cwd))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("dev/file.rb", cwd: cwd))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("./dev/file.html.erb", cwd: cwd))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("./dev/file.html:12", cwd: cwd))
    XCTAssertTrue(TerminalLinkOpener.resolvesToFile("./dev/file.html:12:foo", cwd: cwd))

    XCTAssertFalse(TerminalLinkOpener.resolvesToFile("./dev/missing.rb", cwd: cwd))
  }
}
