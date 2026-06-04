import AppKit
import SwiftTerm

/// Shared link hit-testing for a terminal under the pointer — used by both `LinkCursor` (to show
/// the pointing-hand cursor) and `TerminalLinkOpener` (to open ⌘-clicked links). Everything here
/// derives from SwiftTerm's *public* API: `caretFrame` gives the exact cell size, and
/// `Terminal.link(at: .screen(_), …)` is scrollback-aware — so we never touch SwiftTerm internals
/// (its own hit-testing and link-highlight state are `internal`).
///
/// Deliberately not `@MainActor`: the opener needs a synchronous answer from inside an `NSEvent`
/// monitor (which already runs on the main thread) to decide whether to consume the event.
enum TerminalLinks {
  /// The terminal directly under the pointer in the key window, if any.
  static func terminalUnderMouse() -> LocalProcessTerminalView? {
    guard let window = NSApp.keyWindow, let content = window.contentView else { return nil }
    let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    var view = content.hitTest(point)
    while let current = view {
      if let terminal = current as? LocalProcessTerminalView { return terminal }
      view = current.superview
    }
    return nil
  }

  /// The hyperlink or implicitly-detected path/URL under the pointer in `terminal`, if any.
  /// `.explicitAndImplicit` matches SwiftTerm's own hover-highlight lookup, so the cursor, the
  /// underline, and what we open all agree on what counts as a link.
  static func linkUnderMouse(in terminal: LocalProcessTerminalView) -> String? {
    guard let window = terminal.window else { return nil }
    let point = terminal.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    let core = terminal.getTerminal()
    guard
      let cell = screenCell(
        forMouse: point, bounds: terminal.bounds,
        cell: terminal.caretFrame.size,
        cols: core.cols, rows: core.rows)
    else { return nil }
    return core.link(
      at: .screen(Position(col: cell.col, row: cell.row)), mode: .explicitAndImplicit)
  }

  /// Map a mouse `point` (terminal-view coordinates, bottom-left origin) to the visible cell
  /// under it, or nil if it falls outside the grid. Mirrors SwiftTerm's own hit-test, but in
  /// *screen* (viewport-relative) coordinates rather than absolute buffer rows.
  static func screenCell(
    forMouse point: CGPoint, bounds: CGRect, cell: CGSize, cols: Int, rows: Int
  ) -> (col: Int, row: Int)? {
    guard cell.width > 0, cell.height > 0 else { return nil }
    let col = Int(point.x / cell.width)
    let row = Int((bounds.height - point.y) / cell.height)
    guard (0..<cols).contains(col), (0..<rows).contains(row) else { return nil }
    return (col, row)
  }
}
