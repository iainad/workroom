import XCTest

@testable import Workroom

/// Pure truth-table tests for the dim-scrim and activity-pulse decisions (issue #82). The scrim and
/// border flash are SwiftUI overlays absent from the accessibility tree, so XCUITest can't assert
/// them — these helpers are the automated guard. The focused-never-dims / cursor-never-pulses cases
/// are the regression guards (a future gate edit must not dim the active pane).
final class PaneDimDecisionTests: XCTestCase {

  // MARK: PaneTreeView.shouldDim — (multiPane || !surfaceActive) && !focused && !flashing

  /// ① A focused solo workroom (the active terminal) must never dim. Regression guard.
  func testFocusedSoloActiveDoesNotDim() {
    XCTAssertFalse(
      PaneTreeView.shouldDim(multiPane: false, surfaceActive: true, focused: true, flashing: false))
  }

  /// ② A backgrounded solo workroom dims — the core fix. (surfaceActive: false, solo terminal.)
  func testBackgroundedSoloDims() {
    XCTAssertTrue(
      PaneTreeView.shouldDim(
        multiPane: false, surfaceActive: false, focused: false, flashing: false))
  }

  /// ③ Within a focused workroom's terminal split, the focused pane must not dim. Regression guard.
  func testFocusedMultiFocusedPaneDoesNotDim() {
    XCTAssertFalse(
      PaneTreeView.shouldDim(multiPane: true, surfaceActive: true, focused: true, flashing: false))
  }

  /// ④ Within a focused workroom's terminal split, a non-focused sibling dims (pre-existing).
  func testFocusedMultiSiblingDims() {
    XCTAssertTrue(
      PaneTreeView.shouldDim(multiPane: true, surfaceActive: true, focused: false, flashing: false))
  }

  /// ⑤ Every pane of a backgrounded workroom that itself has a terminal split dims — uniformly, with
  /// one scrim per pane (no double-dim), matching the solo case.
  func testBackgroundedMultiEveryPaneDims() {
    XCTAssertTrue(
      PaneTreeView.shouldDim(multiPane: true, surfaceActive: false, focused: false, flashing: false)
    )
  }

  /// ⑥ An activity flash lifts the dim so the pulse is visible on a backgrounded pane.
  func testFlashingLiftsDim() {
    XCTAssertFalse(
      PaneTreeView.shouldDim(multiPane: true, surfaceActive: false, focused: false, flashing: true))
    XCTAssertFalse(
      PaneTreeView.shouldDim(multiPane: false, surfaceActive: false, focused: false, flashing: true)
    )
  }

  /// A plain solo terminal (project root / single workroom) renders with the default
  /// `surfaceActive: true` and is its own focused pane — it must never dim. This is the safety
  /// property that keeps non-split contexts byte-for-byte unchanged.
  func testPlainSoloNeverDims() {
    XCTAssertFalse(
      PaneTreeView.shouldDim(multiPane: false, surfaceActive: true, focused: true, flashing: false))
    // Even if focusedID is momentarily nil (focused == false), surfaceActive == true blocks the dim.
    XCTAssertFalse(
      PaneTreeView.shouldDim(multiPane: false, surfaceActive: true, focused: false, flashing: false)
    )
  }

  // MARK: AppStore.shouldPulse — isOnScreen && (isSelectedMember ? !isCursorTab : true)

  /// ① The cursor pane of the focused workroom never pulses — you're looking at it.
  func testSelectedMemberCursorTabDoesNotPulse() {
    XCTAssertFalse(
      AppStore.shouldPulse(isOnScreen: true, isSelectedMember: true, isCursorTab: true))
  }

  /// ② A non-cursor pane within the focused workroom's split pulses (pre-existing split-mate flash).
  func testSelectedMemberNonCursorPanePulses() {
    XCTAssertTrue(
      AppStore.shouldPulse(isOnScreen: true, isSelectedMember: true, isCursorTab: false))
  }

  /// ③ Any on-screen pane of a co-displayed NON-selected (backgrounded) workroom pulses — the new
  /// parity. `isCursorTab` is irrelevant when the whole workroom is backgrounded.
  func testCoDisplayedNonSelectedMemberPulses() {
    XCTAssertTrue(
      AppStore.shouldPulse(isOnScreen: true, isSelectedMember: false, isCursorTab: true))
    XCTAssertTrue(
      AppStore.shouldPulse(isOnScreen: true, isSelectedMember: false, isCursorTab: false))
  }

  /// ④ An off-screen pane never pulses (it gets a banner/badge instead).
  func testOffScreenDoesNotPulse() {
    XCTAssertFalse(
      AppStore.shouldPulse(isOnScreen: false, isSelectedMember: false, isCursorTab: false))
    XCTAssertFalse(
      AppStore.shouldPulse(isOnScreen: false, isSelectedMember: true, isCursorTab: false))
  }
}
