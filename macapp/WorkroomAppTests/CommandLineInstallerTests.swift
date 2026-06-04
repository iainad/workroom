import XCTest

@testable import Workroom

/// The install symlink work is filesystem/admin-prompt driven and out of reach of a unit test;
/// the part worth pinning down is the two-layer quoting that builds the privileged
/// `osascript … with administrator privileges` command, so a path with spaces or quotes can't
/// break out of the shell or AppleScript string.
final class CommandLineInstallerTests: XCTestCase {
  func testShellQuotingWrapsInSingleQuotes() {
    XCTAssertEqual(CommandLineInstaller.shellQuoted("/usr/local/bin"), "'/usr/local/bin'")
    XCTAssertEqual(
      CommandLineInstaller.shellQuoted("/Apps/My App/workroom"), "'/Apps/My App/workroom'")
  }

  func testShellQuotingEscapesEmbeddedSingleQuote() {
    // ' closes the quote, '\'' inserts a literal quote, then reopens: /a'b -> '/a'\''b'
    XCTAssertEqual(CommandLineInstaller.shellQuoted("/a'b"), "'/a'\\''b'")
  }

  func testAppleScriptQuotingEscapesBackslashThenQuote() {
    XCTAssertEqual(CommandLineInstaller.appleScriptQuoted("ln -sf a b"), "\"ln -sf a b\"")
    // a\b"c -> escape backslash first (a\\b"c), then the quote (a\\b\"c), then wrap.
    XCTAssertEqual(CommandLineInstaller.appleScriptQuoted("a\\b\"c"), "\"a\\\\b\\\"c\"")
  }

  func testQuotingComposesIntoASafeAdminCommand() {
    // A path with a space survives both layers intact.
    let shell =
      "/bin/ln -sf \(CommandLineInstaller.shellQuoted("/Apps/My App/workroom")) /usr/local/bin/workroom"
    let script = CommandLineInstaller.appleScriptQuoted(shell)
    XCTAssertTrue(script.hasPrefix("\"") && script.hasSuffix("\""))
    XCTAssertTrue(script.contains("'/Apps/My App/workroom'"))
  }
}
