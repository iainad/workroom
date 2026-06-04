import XCTest
@testable import Workroom

/// Covers the pure path classification/resolution behind ⌘-click-to-open. The actual launch
/// (login shell + `$EDITOR`) and the kernel cwd lookup are side-effecting and out of scope here.
final class TerminalLinkOpenerTests: XCTestCase {

    // filePath(from:) — web URLs are left to SwiftTerm (nil); everything else is a path.

    func testWebURLsAreNotFilePaths() {
        for url in ["https://example.com/x", "http://a.b", "mailto:me@x.com", "ssh://host", "git://h/r"] {
            XCTAssertNil(TerminalLinkOpener.filePath(from: url), "\(url) should pass through to the browser handler")
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
        XCTAssertEqual(TerminalLinkOpener.absolutePath(for: "/etc/hosts", cwd: "/somewhere"), "/etc/hosts")
    }

    func testTildeExpands() {
        let home = NSHomeDirectory()
        XCTAssertEqual(TerminalLinkOpener.absolutePath(for: "~/x.txt", cwd: nil), "\(home)/x.txt")
    }

    func testRelativeJoinsCwd() {
        XCTAssertEqual(TerminalLinkOpener.absolutePath(for: "src/main.go", cwd: "/proj"), "/proj/src/main.go")
    }

    func testRelativeWithoutCwdIsNil() {
        // No working directory known → can't resolve a relative path.
        XCTAssertNil(TerminalLinkOpener.absolutePath(for: "src/main.go", cwd: nil))
    }
}
