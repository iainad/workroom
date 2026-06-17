import XCTest

@testable import Workroom

/// The edge-hover reveal decision core (issue #56). Pure value logic (no timers, AppKit, or SwiftUI),
/// so every branch runs headless — the SwiftUI slide animation, the `NSTrackingArea` sensor, and the
/// debounce timing are verified manually/in the UI test, consistent with `ToastQueueTests`' note.
@MainActor
final class EdgeRevealReducerTests: XCTestCase {

  func testSensorEnterRevealsImmediately() {
    var r = EdgeRevealReducer()
    let effect = r.setSensorHover(true)
    XCTAssertTrue(r.revealed)
    XCTAssertEqual(effect, .reveal)
  }

  func testPanelEnterRevealsImmediately() {
    var r = EdgeRevealReducer()
    let effect = r.setPanelHover(true)
    XCTAssertTrue(r.revealed)
    XCTAssertEqual(effect, .reveal)
  }

  func testReEnterWhileRevealedCancelsHide() {
    var r = EdgeRevealReducer()
    _ = r.setSensorHover(true)  // reveal
    // Already revealed; a second hover signal must not re-reveal, just cancel any pending hide.
    let effect = r.setPanelHover(true)
    XCTAssertTrue(r.revealed)
    XCTAssertEqual(effect, .cancelHide)
  }

  func testSeamCrossSensorToPanelStaysRevealed() {
    var r = EdgeRevealReducer()
    _ = r.setSensorHover(true)  // reveal via sensor
    _ = r.setPanelHover(true)  // cursor now over panel too
    // Cursor leaves the sensor strip but is still over the panel — must NOT schedule a hide.
    let effect = r.setSensorHover(false)
    XCTAssertTrue(r.revealed)
    XCTAssertEqual(effect, .cancelHide)
    XCTAssertTrue(r.wantsVisible)
  }

  func testLeavingBothSchedulesHideButStaysVisibleUntilCommit() {
    var r = EdgeRevealReducer()
    _ = r.setSensorHover(true)
    let effect = r.setSensorHover(false)  // nothing hovered now
    XCTAssertEqual(effect, .scheduleHide)
    // Still revealed — the view's debounce hasn't fired yet.
    XCTAssertTrue(r.revealed)
  }

  func testCommitHideWhenIdleHides() {
    var r = EdgeRevealReducer()
    _ = r.setSensorHover(true)
    _ = r.setSensorHover(false)
    let changed = r.commitHideIfStillIdle()
    XCTAssertTrue(changed)
    XCTAssertFalse(r.revealed)
  }

  func testCommitHideWhenReHoveredIsNoOp() {
    var r = EdgeRevealReducer()
    _ = r.setSensorHover(true)
    _ = r.setSensorHover(false)  // schedule hide
    _ = r.setPanelHover(true)  // cursor came back before the timer fired
    let changed = r.commitHideIfStillIdle()
    XCTAssertFalse(changed)  // race guard: still hovered, don't hide
    XCTAssertTrue(r.revealed)
  }

  func testReHoverAfterScheduleCancelsHide() {
    var r = EdgeRevealReducer()
    _ = r.setSensorHover(true)
    _ = r.setSensorHover(false)  // schedule hide
    let effect = r.setSensorHover(true)  // back before commit
    XCTAssertEqual(effect, .cancelHide)
    XCTAssertTrue(r.revealed)
  }

  func testDisableForcesHiddenAndClearsHover() {
    var r = EdgeRevealReducer()
    _ = r.setSensorHover(true)
    let wasActive = r.disable()
    XCTAssertTrue(wasActive)
    XCTAssertFalse(r.revealed)
    XCTAssertFalse(r.wantsVisible)
  }

  func testDisableWhenIdleReportsInactive() {
    var r = EdgeRevealReducer()
    XCTAssertFalse(r.disable())
    XCTAssertFalse(r.revealed)
  }

  func testDismissWhenRevealedHidesAndClearsHover() {
    var r = EdgeRevealReducer()
    _ = r.setPanelHover(true)
    let was = r.dismiss()
    XCTAssertTrue(was)
    XCTAssertFalse(r.revealed)
    XCTAssertFalse(r.wantsVisible)
  }

  func testDismissWhenHiddenIsNoOp() {
    var r = EdgeRevealReducer()
    XCTAssertFalse(r.dismiss())
  }

  func testNoEffectWhenLeavingWhileAlreadyHidden() {
    var r = EdgeRevealReducer()
    // Never revealed; a stray exit signal does nothing.
    let effect = r.setSensorHover(false)
    XCTAssertEqual(effect, .none)
    XCTAssertFalse(r.revealed)
  }
}
