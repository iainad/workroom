import CoreGraphics
import XCTest

@testable import Workroom

/// Unit tests for the pure drag-to-reorder math extracted from `TerminalTabStrip` (issue #23 prep).
/// These pin the behavior that both the terminal tab strip and the Workrooms tab bar depend on.
final class TabReorderMathTests: XCTestCase {
  // Three equal 100pt chips with 4pt spacing → each neighbour's span is 104, half-span 52.
  private let widths: [CGFloat] = [100, 100, 100]
  private let spacing: CGFloat = 4

  // MARK: dropTargetIndex

  func testNoTranslationStaysPut() {
    XCTAssertEqual(
      TabReorder.dropTargetIndex(widths: widths, draggedIndex: 1, translation: 0, spacing: spacing),
      1)
  }

  func testSmallTranslationDoesNotCross() {
    // 40 < half-span (52) → no crossing.
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 0, translation: 40, spacing: spacing),
      0)
  }

  func testDragRightCrossesOneNeighbour() {
    // 60 > 52 (one half-span) but < 156 → land on index 1.
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 0, translation: 60, spacing: spacing),
      1)
  }

  func testDragRightCrossesTwoNeighboursToLastSlot() {
    // 160 > 52 and > 104+52=156 → land on the last index.
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 0, translation: 160, spacing: spacing),
      2)
  }

  func testDragLeftCrossesOneNeighbour() {
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 2, translation: -60, spacing: spacing),
      1)
  }

  func testDragLeftReachesFirstSlot() {
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 2, translation: -160, spacing: spacing),
      0)
  }

  func testDragRightClampsAtLastSlot() {
    // Huge translation can't exceed the last index.
    XCTAssertEqual(
      TabReorder.dropTargetIndex(
        widths: widths, draggedIndex: 0, translation: 99_999, spacing: spacing),
      2)
  }

  // MARK: gapShift

  func testGapShiftNilTargetIsZero() {
    XCTAssertEqual(
      TabReorder.gapShift(index: 1, draggedIndex: 0, target: nil, amount: 104), 0)
    XCTAssertEqual(
      TabReorder.gapShift(index: 1, draggedIndex: nil, target: 2, amount: 104), 0)
  }

  func testGapShiftDraggingRightSlidesInterveningChipsLeft() {
    // Dragging 0 → 2: chips at 1 and 2 slide left by `amount`; chip 0 (the dragged slot) doesn't.
    XCTAssertEqual(TabReorder.gapShift(index: 1, draggedIndex: 0, target: 2, amount: 104), -104)
    XCTAssertEqual(TabReorder.gapShift(index: 2, draggedIndex: 0, target: 2, amount: 104), -104)
    XCTAssertEqual(TabReorder.gapShift(index: 0, draggedIndex: 0, target: 2, amount: 104), 0)
  }

  func testGapShiftDraggingLeftSlidesInterveningChipsRight() {
    // Dragging 2 → 0: chips at 0 and 1 slide right by `amount`; chip 2 doesn't.
    XCTAssertEqual(TabReorder.gapShift(index: 0, draggedIndex: 2, target: 0, amount: 104), 104)
    XCTAssertEqual(TabReorder.gapShift(index: 1, draggedIndex: 2, target: 0, amount: 104), 104)
    XCTAssertEqual(TabReorder.gapShift(index: 2, draggedIndex: 2, target: 0, amount: 104), 0)
  }
}
