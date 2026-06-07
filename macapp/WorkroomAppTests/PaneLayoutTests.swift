import XCTest

@testable import Workroom

/// Pure-tree tests for `PaneLayout` (issue #3). No surfaces needed — leaves are tab ids.
final class PaneLayoutTests: XCTestCase {
  private let a = UUID()
  private let b = UUID()
  private let c = UUID()
  private let d = UUID()

  func testTabIDsReadingOrderNested() {
    // split(h, leaf(a), split(v, leaf(b), leaf(c)))  →  [a, b, c]
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(id: UUID(), orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c))
    )
    XCTAssertEqual(tree.tabIDs, [a, b, c])
    XCTAssertEqual(tree.firstTabID, a)
    XCTAssertTrue(tree.contains(c))
    XCTAssertFalse(tree.contains(d))
  }

  func testInsertingBesideLeaf() {
    // leaf(a) + b on the trailing side → split(a, b)
    let tree = PaneLayout.leaf(a)
      .inserting(b, beside: a, orientation: .horizontal, newLeafFirst: false, ratio: 0.5)
    XCTAssertEqual(tree.tabIDs, [a, b])
    // newLeafFirst puts the new pane first.
    let leading = PaneLayout.leaf(a)
      .inserting(b, beside: a, orientation: .vertical, newLeafFirst: true, ratio: 0.5)
    XCTAssertEqual(leading.tabIDs, [b, a])
  }

  func testInsertingDeepInTree() {
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)
    ).inserting(c, beside: b, orientation: .vertical, newLeafFirst: false, ratio: 0.5)
    XCTAssertEqual(tree.tabIDs, [a, b, c])
  }

  func testRemovingLeafCollapsesToSibling() {
    let split = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
    // Remove a → the sibling leaf(b) remains (a single leaf — caller dissolves the split).
    let collapsed = split.removingLeaf(a)
    XCTAssertEqual(collapsed, .leaf(b))
    XCTAssertEqual(collapsed?.tabIDs.count, 1)
  }

  func testRemovingLeafFromThreePaneKeepsSplit() {
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(id: UUID(), orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
    let collapsed = tree.removingLeaf(b)
    XCTAssertEqual(collapsed?.tabIDs, [a, c])  // inner split collapses to c; outer keeps a|c
  }

  func testRemovingWholeLeafReturnsNil() {
    XCTAssertNil(PaneLayout.leaf(a).removingLeaf(a))
    XCTAssertEqual(PaneLayout.leaf(a).removingLeaf(b), .leaf(a))  // not present → unchanged
  }

  func testSettingRatioTargetsOneNode() {
    let inner = UUID()
    let tree = PaneLayout.split(
      id: UUID(), orientation: .horizontal, ratio: 0.5,
      first: .leaf(a),
      second: .split(id: inner, orientation: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
    let updated = tree.settingRatio(0.8, forSplit: inner)
    if case .split(_, _, _, _, .split(_, _, let r, _, _)) = updated {
      XCTAssertEqual(r, 0.8, accuracy: 0.0001)
    } else {
      XCTFail("inner split not found")
    }
  }

  func testRatioSanitizeClampsOpenInterval() {
    XCTAssertEqual(PaneLayout.sanitize(0), 0.001, accuracy: 0.0001)
    XCTAssertEqual(PaneLayout.sanitize(1), 0.999, accuracy: 0.0001)
    XCTAssertEqual(PaneLayout.sanitize(0.5), 0.5, accuracy: 0.0001)
  }
}
