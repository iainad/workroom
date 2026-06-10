import XCTest

@testable import Workroom

/// `UnreadCount.label` is the one place the unread cap lives, shared by the toolbar `UnreadBadge`
/// and the menu bar item so they can't drift. Below the cap it's the bare number; at 100+ it's
/// "99+".
final class UnreadCountTests: XCTestCase {
  func testBelowCapIsBareNumber() {
    XCTAssertEqual(UnreadCount.label(0), "0")
    XCTAssertEqual(UnreadCount.label(1), "1")
    XCTAssertEqual(UnreadCount.label(42), "42")
    XCTAssertEqual(UnreadCount.label(99), "99")
  }

  func testAtAndAboveCapIsNinetyNinePlus() {
    XCTAssertEqual(UnreadCount.label(100), "99+")
    XCTAssertEqual(UnreadCount.label(1000), "99+")
  }
}
