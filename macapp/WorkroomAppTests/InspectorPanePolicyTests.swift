import AppKit
import XCTest

@testable import Workroom

/// Headless unit tests for the inspector's pure sizing policy (`InspectorPanePolicy`). These run in
/// `make app-test` with no GUI session — the bug-prone sizing decisions (collapse pinning, equal
/// default, weighted resize, floors) are verified here, not in XCUITest (which needs a GUI and is
/// blocked in some dev sessions). The raw `NSSplitView`'s actual frame distribution is Apple's code,
/// verified by manual QA; this file covers the policy that feeds it in isolation.
final class InspectorPanePolicyTests: XCTestCase {
  private let header = InspectorPanePolicy.headerHeight
  private let minH = InspectorPanePolicy.expandedMinHeight
  private let divider: CGFloat = 1

  // MARK: constraints

  func testCollapsedPaneIsPinnedToHeader() {
    let con = InspectorPanePolicy.constraints(collapsed: true)
    XCTAssertEqual(con.minHeight, header)
    XCTAssertEqual(con.maxHeight, header)
    XCTAssertTrue(con.isPinned)
  }

  func testExpandedPaneIsFlooredAndUnbounded() {
    let con = InspectorPanePolicy.constraints(collapsed: false)
    XCTAssertEqual(con.minHeight, minH, "expanded pane floors at the sensible minimum")
    XCTAssertEqual(con.maxHeight, .greatestFiniteMagnitude, "expanded pane has no ceiling")
    XCTAssertFalse(con.isPinned)
    XCTAssertLessThan(
      con.holdingPriority.rawValue, NSLayoutConstraint.Priority.defaultHigh.rawValue,
      "expanded panes hold low so a window resize is absorbed here, not by a pinned pane")
  }

  // MARK: allocate — equal default when all expanded

  func testAllExpandedSplitsEqually() {
    let capacity: CGFloat = 600
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false, false], capacity: capacity, dividerThickness: divider)
    XCTAssertEqual(h[0], h[1], accuracy: 0.5)
    XCTAssertEqual(h[1], h[2], accuracy: 0.5)
    XCTAssertEqual(h.reduce(0, +) + 2 * divider, capacity, accuracy: 0.5, "panes + dividers fill")
    XCTAssertGreaterThan(h[0], minH, "each equal third is well above the floor at this capacity")
  }

  // MARK: allocate — collapse pins to header and redistributes the rest

  func testCollapsedSectionPinnedAndRestSplitEqually() {
    let capacity: CGFloat = 600
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, true, false], capacity: capacity, dividerThickness: divider)
    XCTAssertEqual(h[1], header, accuracy: 0.5, "collapsed pane is exactly the header")
    XCTAssertEqual(h[0], h[2], accuracy: 0.5, "the two expanded panes share the rest equally")
    XCTAssertEqual(h.reduce(0, +) + 2 * divider, capacity, accuracy: 0.5)
  }

  func testAllCollapsedAreAllHeaders() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [true, true, true], capacity: 600, dividerThickness: divider)
    XCTAssertEqual(h, [header, header, header])
  }

  // MARK: allocate — persisted weights drive proportional resize

  func testWeightsDriveProportionalSplit() {
    let capacity: CGFloat = 600
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false, false], weights: [2, 1, 1], capacity: capacity,
      dividerThickness: divider)
    XCTAssertEqual(h[1], h[2], accuracy: 0.5, "equal weights → equal heights")
    XCTAssertEqual(h[0], 2 * h[1], accuracy: 1.0, "double weight → double height")
  }

  func testWeightsRenormaliseAmongExpandedPanes() {
    // Pane 0 collapsed: its weight is irrelevant; panes 1 & 2 keep their 1:1 ratio.
    let h = InspectorPanePolicy.allocate(
      collapsed: [true, false, false], weights: [99, 1, 1], capacity: 600, dividerThickness: divider
    )
    XCTAssertEqual(h[0], header, accuracy: 0.5)
    XCTAssertEqual(h[1], h[2], accuracy: 0.5, "collapsed pane's weight doesn't distort the rest")
  }

  // MARK: allocate — floors hold when the split is too short (panes scroll)

  func testCrampedExpandedPanesGetTheirFloor() {
    // Three expanded panes can't all fit their floor in this capacity; each still gets the floor
    // (and overflows into its own scroll view rather than vanishing).
    let capacity = minH * 2  // less than 3 * floor
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false, false], capacity: capacity, dividerThickness: divider)
    for height in h {
      XCTAssertGreaterThanOrEqual(height, minH, "expanded panes never dip below floor")
    }
  }

  func testZeroCapacityIsAllZeros() {
    let h = InspectorPanePolicy.allocate(
      collapsed: [false, false, false], capacity: 0, dividerThickness: divider)
    XCTAssertEqual(h, [0, 0, 0])
  }
}
