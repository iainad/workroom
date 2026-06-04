import XCTest

@testable import Workroom

/// The OSC notification grammar (issue #10): explicit-only detection parses OSC 9/99/777
/// payloads (raw, un-decoded bytes — exactly what SwiftTerm hands a registered handler).
final class OSCParserTests: XCTestCase {
  private func bytes(_ s: String) -> ArraySlice<UInt8> { Array(s.utf8)[...] }

  // MARK: OSC 777 (urxvt/tmux: notify;title;body)

  func testOSC777Valid() {
    XCTAssertEqual(
      OSCNotification.parse(code: 777, bytes("notify;Build;done")),
      .osc(title: "Build", body: "done"))
  }

  func testOSC777BodyMayContainSemicolons() {
    XCTAssertEqual(
      OSCNotification.parse(code: 777, bytes("notify;Title;a;b;c")),
      .osc(title: "Title", body: "a;b;c"))
  }

  func testOSC777EmptyBodyNormalizesToNil() {
    XCTAssertEqual(
      OSCNotification.parse(code: 777, bytes("notify;Title;")),
      .osc(title: "Title", body: nil))
  }

  func testOSC777MissingFieldsRejected() {
    XCTAssertNil(OSCNotification.parse(code: 777, bytes("notify;onlytitle")))
    XCTAssertNil(OSCNotification.parse(code: 777, bytes("other;Title;Body")))
  }

  // MARK: OSC 9 (iTerm2 growl vs ConEmu progress)

  func testOSC9MessageBecomesTitle() {
    XCTAssertEqual(
      OSCNotification.parse(code: 9, bytes("Build done")), .osc(title: "Build done", body: nil))
  }

  func testOSC9ProgressReportIgnored() {
    XCTAssertNil(OSCNotification.parse(code: 9, bytes("4;1;50")))
  }

  func testOSC9BlankIgnored() {
    XCTAssertNil(OSCNotification.parse(code: 9, bytes("   ")))
  }

  // MARK: OSC 99 (kitty, common single-message case)

  func testOSC99WithMetadata() {
    XCTAssertEqual(
      OSCNotification.parse(code: 99, bytes("i=1;Hello")), .osc(title: "Hello", body: nil))
  }

  func testOSC99NoMetadata() {
    XCTAssertEqual(OSCNotification.parse(code: 99, bytes("Hello")), .osc(title: "Hello", body: nil))
  }

  func testOSC99ChunkedContinuationIgnored() {
    XCTAssertNil(OSCNotification.parse(code: 99, bytes("i=1:d=0;partial")))
  }

  // MARK: Cross-cutting

  func testNonUTF8PayloadRejected() {
    let bad: [UInt8] = [0xFF, 0xFE, 0xFD]
    XCTAssertNil(OSCNotification.parse(code: 9, bad[...]))
    XCTAssertNil(OSCNotification.parse(code: 777, bad[...]))
    XCTAssertNil(OSCNotification.parse(code: 99, bad[...]))
  }

  func testUnhandledCodeRejected() {
    XCTAssertNil(OSCNotification.parse(code: 52, bytes("clipboard")))
  }
}
