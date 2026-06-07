import Defaults
import XCTest

@testable import Workroom

/// `Defaults[.confirmOnCloseTerminal]` must default to ON (issue #27 asks for a setting that's
/// enabled by default) — the key is absent until the user first toggles it — and otherwise honour
/// the stored value. The `Key`'s `default: true` is what guarantees the default.
final class ConfirmOnCloseTerminalTests: XCTestCase {

  /// The raw UserDefaults key behind `Defaults.Keys.confirmOnCloseTerminal` — used only to
  /// save/restore the real stored value so the test never leaks into the user's defaults.
  private let key = "confirmOnCloseTerminal"
  private var saved: Any?

  override func setUp() {
    super.setUp()
    saved = UserDefaults.standard.object(forKey: key)
  }

  override func tearDown() {
    if let saved {
      UserDefaults.standard.set(saved, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
    super.tearDown()
  }

  func testEnabledByDefaultWhenUnset() {
    UserDefaults.standard.removeObject(forKey: key)
    XCTAssertTrue(Defaults[.confirmOnCloseTerminal])
  }

  func testRespectsStoredValue() {
    Defaults[.confirmOnCloseTerminal] = false
    XCTAssertFalse(Defaults[.confirmOnCloseTerminal])

    Defaults[.confirmOnCloseTerminal] = true
    XCTAssertTrue(Defaults[.confirmOnCloseTerminal])
  }
}
