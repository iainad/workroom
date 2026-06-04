import XCTest
@testable import Workroom

/// Covers the pure coordinate math behind link hit-testing. The live behaviour (modifier state,
/// hit-testing the key window, the SwiftTerm link lookup) is AppKit/mouse-driven and out of reach
/// of a unit test; the grid mapping below is the part worth pinning down.
final class TerminalLinksTests: XCTestCase {
    // 8×16pt cells over an 80×160pt view → a 10-column, 10-row grid.
    private let cell = CGSize(width: 8, height: 16)
    private let bounds = CGRect(x: 0, y: 0, width: 80, height: 160)

    func testTopLeftMapsToRowZero() {
        // Bottom-left origin: a high y is near the top, so it lands on row 0.
        let hit = TerminalLinks.screenCell(forMouse: CGPoint(x: 1, y: 159), bounds: bounds, cell: cell, cols: 10, rows: 10)
        XCTAssertEqual(hit?.col, 0)
        XCTAssertEqual(hit?.row, 0)
    }

    func testInteriorCell() {
        // x 12 → col 1; y 140 → (160-140)/16 = 1.25 → row 1.
        let hit = TerminalLinks.screenCell(forMouse: CGPoint(x: 12, y: 140), bounds: bounds, cell: cell, cols: 10, rows: 10)
        XCTAssertEqual(hit?.col, 1)
        XCTAssertEqual(hit?.row, 1)
    }

    func testBottomRightCorner() {
        // x 79 → col 9; y 1 → (160-1)/16 = 9.9 → row 9.
        let hit = TerminalLinks.screenCell(forMouse: CGPoint(x: 79, y: 1), bounds: bounds, cell: cell, cols: 10, rows: 10)
        XCTAssertEqual(hit?.col, 9)
        XCTAssertEqual(hit?.row, 9)
    }

    func testPointBeyondGridIsNil() {
        // x == width → col 10, which is outside a 10-column grid.
        XCTAssertNil(TerminalLinks.screenCell(forMouse: CGPoint(x: 80, y: 80), bounds: bounds, cell: cell, cols: 10, rows: 10))
    }

    func testDegenerateCellSizeIsNil() {
        // No caret view yet (caretFrame == .zero) must not divide by zero.
        XCTAssertNil(TerminalLinks.screenCell(forMouse: CGPoint(x: 4, y: 80), bounds: bounds, cell: .zero, cols: 10, rows: 10))
    }
}
