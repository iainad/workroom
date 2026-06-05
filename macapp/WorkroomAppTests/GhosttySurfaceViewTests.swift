import XCTest

@testable import Workroom

/// Guards the keyboard-input regression we hit during QA: macOS reports arrows / F-keys / nav keys
/// as function-key private-use scalars (U+F700–U+F8FF), which must NOT be forwarded as text (else
/// they insert a stray glyph), while DEL (U+007F, the Backspace key) MUST be kept and forwarded so
/// the shell receives the erase byte. See `GhosttySurfaceView.filterSpecialCharacters`.
final class TerminalKeyTextFilterTests: XCTestCase {
  private func filter(_ s: String) -> String { GhosttySurfaceView.filterSpecialCharacters(s) }

  func testEmptyStringStaysEmpty() {
    XCTAssertEqual(filter(""), "")
  }

  func testPlainTextPassesThrough() {
    XCTAssertEqual(filter("a"), "a")
    XCTAssertEqual(filter("é"), "é")
    XCTAssertEqual(filter("abc"), "abc")  // first scalar decides; whole string returned
  }

  func testFunctionKeyPrivateUseRangeIsDropped() {
    // The bug: these passed the old `>= 0x20` filter and got sent as text → "weird characters".
    XCTAssertEqual(filter("\u{F700}"), "", "up-arrow sentinel must be dropped")
    XCTAssertEqual(filter("\u{F701}"), "", "down-arrow sentinel must be dropped")
    XCTAssertEqual(filter("\u{F8FF}"), "", "end of the PUA function-key range must be dropped")
  }

  func testControlCharactersAreDropped() {
    XCTAssertEqual(filter("\u{0008}"), "", "BS (^H) is a control char")
    XCTAssertEqual(filter("\u{001B}"), "", "ESC is a control char")
    XCTAssertEqual(filter("\u{000D}"), "", "CR is a control char")
  }

  func testDelIsKept() {
    // The backspace fix: DEL (0x7F) must be forwarded as text (libghostty 1.2.3 mis-encodes the
    // backspace *keycode*, so we send the byte instead).
    XCTAssertEqual(filter("\u{007F}"), "\u{007F}")
  }
}

/// Guards the overlay-scrollbar geometry (the indicator restored after the SwiftTerm → libghostty
/// migration). Pure math over libghostty's `total`/`offset`/`len` (rows). Bottom-left origin: the
/// live position sits at the bottom of the track. See `GhosttySurfaceView.scrollbarThumbRect`.
final class ScrollbarGeometryTests: XCTestCase {
  // 200pt track: bounds height 204 minus 2*inset(2).
  private let bounds = CGRect(x: 0, y: 0, width: 100, height: 204)
  private let width: CGFloat = 7
  private let inset: CGFloat = 2
  private let minThumb: CGFloat = 28

  private func rect(total: UInt64, offset: UInt64, len: UInt64) -> CGRect? {
    GhosttySurfaceView.scrollbarThumbRect(
      total: total, offset: offset, len: len, bounds: bounds,
      width: width, inset: inset, minThumb: minThumb)
  }

  func testHiddenWhenNothingToScroll() {
    XCTAssertNil(rect(total: 200, offset: 0, len: 200), "viewport == buffer → no thumb")
    XCTAssertNil(rect(total: 100, offset: 0, len: 200), "len > total (degenerate) → no thumb")
  }

  func testThumbSizeIsProportional() throws {
    // total 400, len 200 → half the 200pt track = 100pt thumb.
    let r = try XCTUnwrap(rect(total: 400, offset: 200, len: 200))
    XCTAssertEqual(r.height, 100, accuracy: 0.001)
    XCTAssertEqual(r.width, width)
    XCTAssertEqual(r.origin.x, bounds.width - width - inset, accuracy: 0.001)  // right edge
  }

  func testLivePositionSitsAtBottom() throws {
    // offset == total - len == live: thumb at the bottom (y == inset).
    let r = try XCTUnwrap(rect(total: 400, offset: 200, len: 200))
    XCTAssertEqual(r.origin.y, inset, accuracy: 0.001)
  }

  func testScrolledToTopSitsAtTop() throws {
    // offset 0: thumb at the top (y == inset + (track - thumb)).
    let r = try XCTUnwrap(rect(total: 400, offset: 0, len: 200))
    XCTAssertEqual(r.origin.y, inset + (200 - 100), accuracy: 0.001)
  }

  func testThumbClampsToMinimumHeight() throws {
    // Huge scrollback: proportional height (200*200/10000 = 4) clamps up to minThumb.
    let r = try XCTUnwrap(rect(total: 10000, offset: 0, len: 200))
    XCTAssertEqual(r.height, minThumb, accuracy: 0.001)
  }

  func testShouldFlashOnlyWhenScrolledBack() {
    // Live (at bottom) → no flash; scrolled back → flash; nothing-to-scroll → no flash.
    XCTAssertFalse(GhosttySurfaceView.scrollbarShouldFlash(total: 400, offset: 200, len: 200))
    XCTAssertTrue(GhosttySurfaceView.scrollbarShouldFlash(total: 400, offset: 100, len: 200))
    XCTAssertTrue(GhosttySurfaceView.scrollbarShouldFlash(total: 400, offset: 0, len: 200))
    XCTAssertFalse(GhosttySurfaceView.scrollbarShouldFlash(total: 200, offset: 0, len: 200))
  }
}
