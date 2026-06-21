import XCTest

@testable import Workroom

/// The toolbar pill is driven by `Updater.availableVersionString`. Sparkle's scheduled checks are off
/// in Debug (and tests run Debug), so constructing `Updater` fires no network check — we can assert
/// the pill state transitions directly without a live Sparkle session.
@MainActor
final class UpdaterTests: XCTestCase {
  func testStartsWithNoAvailableUpdate() {
    XCTAssertNil(Updater().availableVersionString)
  }

  func testSetAndClearAvailableDrivesPillState() {
    let updater = Updater()
    updater.setAvailable("2.0.0")
    XCTAssertEqual(updater.availableVersionString, "2.0.0")
    updater.clearAvailable()
    XCTAssertNil(updater.availableVersionString)
  }
}
