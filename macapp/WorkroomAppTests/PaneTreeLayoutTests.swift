import XCTest

@testable import Workroom

/// Pure split-geometry math used by the pane renderer (plan D5). Extracting it keeps the trickiest
/// arithmetic in the feature unit-testable even though the SwiftUI views themselves aren't.
final class PaneTreeLayoutTests: XCTestCase {
  private let divider = TerminalSessions.dividerThickness  // 7
  private let minPane = TerminalSessions.minPaneSize  // 120

  func testLengthsSumToUsableAndSplitEvenly() {
    let (a, b) = PaneTreeLayout.lengths(total: 1000, ratio: 0.5)
    XCTAssertEqual(a + b, 1000 - divider, accuracy: 0.5)
    XCTAssertEqual(a, b, accuracy: 1.5)  // even ±rounding
  }

  func testLengthsClampSecondToMinPane() {
    let (a, b) = PaneTreeLayout.lengths(total: 1000, ratio: 0.95)
    XCTAssertEqual(b, minPane, accuracy: 0.5)  // second can't go below minPane
    XCTAssertEqual(a + b, 1000 - divider, accuracy: 0.5)
  }

  func testLengthsClampFirstToMinPane() {
    let (a, _) = PaneTreeLayout.lengths(total: 1000, ratio: 0.01)
    XCTAssertEqual(a, minPane, accuracy: 0.5)
  }

  func testLengthsTooSmallFallsBackToEven() {
    let (a, b) = PaneTreeLayout.lengths(total: 200, ratio: 0.9)
    XCTAssertEqual(a + b, 200 - divider, accuracy: 0.5)
    XCTAssertEqual(a, b, accuracy: 1.5)  // ignores ratio when it can't honor minPane
  }

  func testClampRatioKeepsBothPanesUsable() {
    let usable = 1000 - divider
    let minR = minPane / usable
    XCTAssertEqual(PaneTreeLayout.clampRatio(0.99, total: 1000), 1 - minR, accuracy: 0.001)
    XCTAssertEqual(PaneTreeLayout.clampRatio(0.0, total: 1000), minR, accuracy: 0.001)
    XCTAssertEqual(PaneTreeLayout.clampRatio(0.5, total: 1000), 0.5, accuracy: 0.001)
  }

  func testClampRatioTooSmallCentres() {
    XCTAssertEqual(PaneTreeLayout.clampRatio(0.9, total: 200), 0.5, accuracy: 0.001)
  }

  // MARK: Drop targeting (Phase 2)

  func testNearestEdgePicksTheNearerSide() {
    let r = CGRect(x: 0, y: 0, width: 100, height: 100)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 10, y: 50), in: r), .left)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 90, y: 50), in: r), .right)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 50, y: 10), in: r), .top)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 50, y: 90), in: r), .bottom)
  }

  func testNearestEdgeAccountsForAspect() {
    let wide = CGRect(x: 0, y: 0, width: 400, height: 100)
    // Near the top-center of a wide pane → top, not left, because edges tile by normalised distance.
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 200, y: 10), in: wide), .top)
    XCTAssertEqual(PaneTreeLayout.nearestEdge(of: CGPoint(x: 20, y: 50), in: wide), .left)
  }

  func testDropTargetFindsPaneOrNil() {
    let a = UUID()
    let b = UUID()
    let panes = [
      a: CGRect(x: 0, y: 0, width: 100, height: 100),
      b: CGRect(x: 107, y: 0, width: 100, height: 100),
    ]
    let hitA = PaneTreeLayout.dropTarget(at: CGPoint(x: 90, y: 50), panes: panes)
    XCTAssertEqual(hitA?.tab, a)
    XCTAssertEqual(hitA?.edge, .right)
    XCTAssertEqual(PaneTreeLayout.dropTarget(at: CGPoint(x: 150, y: 50), panes: panes)?.tab, b)
    XCTAssertNil(PaneTreeLayout.dropTarget(at: CGPoint(x: 500, y: 50), panes: panes))  // gap/outside
  }

  func testEdgeBandIsHalfThePane() {
    let r = CGRect(x: 0, y: 0, width: 100, height: 80)
    XCTAssertEqual(PaneTreeLayout.edgeBand(.right, in: r), CGRect(x: 50, y: 0, width: 50, height: 80))
    XCTAssertEqual(PaneTreeLayout.edgeBand(.top, in: r), CGRect(x: 0, y: 0, width: 100, height: 40))
    XCTAssertEqual(
      PaneTreeLayout.edgeBand(.bottom, in: r), CGRect(x: 0, y: 40, width: 100, height: 40))
  }
}
