import XCTest

@testable import Workroom

final class CopyOnSelectTests: XCTestCase {

  private let key = CopyOnSelect.storageKey
  private var saved: Any?

  override func setUp() {
    super.setUp()
    saved = UserDefaults.standard.object(forKey: key)
  }

  override func tearDown() {
    // Restore the real preference so the test doesn't leak into the user's defaults.
    if let saved {
      UserDefaults.standard.set(saved, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
    super.tearDown()
  }

  /// The chosen default is ON: copy-on-select must be enabled until the user explicitly
  /// turns it off. The key is absent until the menu toggle first writes it, so "unset"
  /// has to read as `true` (a plain `bool(forKey:)` would wrongly default to `false`).
  func testEnabledByDefaultWhenUnset() {
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertTrue(CopyOnSelect.isEnabled)
  }

  func testRespectsStoredValue() {
    UserDefaults.standard.set(false, forKey: key)
    XCTAssertFalse(CopyOnSelect.isEnabled)

    UserDefaults.standard.set(true, forKey: key)
    XCTAssertTrue(CopyOnSelect.isEnabled)
  }
}
