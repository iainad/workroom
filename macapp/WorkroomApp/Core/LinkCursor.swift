import AppKit
import SwiftTerm

/// Shows the pointing-hand cursor while the pointer is over a ⌘-clickable link or path in a
/// terminal — the affordance every macOS terminal/editor uses to say "this is clickable".
///
/// SwiftTerm makes links clickable only while ⌘ is held (its default `.hoverWithModifier`),
/// underlining the link under the pointer; this matches the cursor to that state. The work is
/// driven from `NSEvent` monitors in `AppDelegate`: a `.mouseMoved` monitor for movement while
/// ⌘ is held (SwiftTerm only emits moved events then), and a `.flagsChanged` monitor to catch
/// ⌘ press/release while the pointer is stationary. Monitors — not a `cursorUpdate` override —
/// because SwiftTerm's cursor methods (`cursorUpdate`/`resetCursorRects`) are `public`, not
/// `open`, so they can't be overridden from this module. (Same reason `CopyOnSelect` uses one.)
///
/// Detection uses public API only: `caretFrame` gives the exact cell size, and
/// `Terminal.link(at: .screen(_), …)` is scrollback-aware — so we never reach into SwiftTerm
/// internals (its hit-testing and link-highlight state are `internal`).
@MainActor
enum LinkCursor {
    /// Whether *we* last forced the pointing-hand cursor. We only restore the I-beam when we
    /// were the one who changed it, so we never stomp on cursors owned by other views.
    private static var pointerActive = false

    /// Re-evaluate the cursor for the current pointer location and modifier state. Cheap and
    /// idempotent — safe to call on every mouse-moved / flags-changed event.
    static func update() {
        let terminal = terminalUnderMouse()
        if let terminal,
           NSEvent.modifierFlags.contains(.command),
           isOverLink(terminal) {
            NSCursor.pointingHand.set()
            pointerActive = true
        } else if pointerActive {
            // Moving off a link *within* a terminal needs an explicit reset — no cursor-rect
            // boundary is crossed, so AppKit won't restore the I-beam on its own. Once the
            // pointer has left the terminal entirely, the destination view's cursor rect
            // reasserts itself on the crossing, so we just drop our override rather than flash
            // an I-beam over, say, the sidebar.
            if terminal != nil { NSCursor.iBeam.set() }
            pointerActive = false
        }
    }

    /// The terminal directly under the pointer in the key window, if any.
    private static func terminalUnderMouse() -> LocalProcessTerminalView? {
        guard let window = NSApp.keyWindow, let content = window.contentView else { return nil }
        let point = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        var view = content.hitTest(point)
        while let current = view {
            if let terminal = current as? LocalProcessTerminalView { return terminal }
            view = current.superview
        }
        return nil
    }

    /// Whether the pointer sits over a hyperlink or implicitly-detected path/URL in `terminal`.
    private static func isOverLink(_ terminal: LocalProcessTerminalView) -> Bool {
        let point = terminal.convert(terminal.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let core = terminal.getTerminal()
        guard let cell = screenCell(forMouse: point, bounds: terminal.bounds,
                                    cell: terminal.caretFrame.size,
                                    cols: core.cols, rows: core.rows) else { return false }
        // `.screen` coordinates are viewport-relative, so the lookup stays correct under
        // scrollback. `.explicitAndImplicit` matches SwiftTerm's own hover-highlight lookup,
        // so the cursor and the underline agree on what counts as a link.
        return core.link(at: .screen(Position(col: cell.col, row: cell.row)),
                         mode: .explicitAndImplicit) != nil
    }

    /// Map a mouse `point` (terminal-view coordinates, bottom-left origin) to the visible cell
    /// under it, or nil if it falls outside the grid. Mirrors SwiftTerm's own hit-test, but in
    /// *screen* (viewport-relative) coordinates rather than absolute buffer rows.
    nonisolated static func screenCell(
        forMouse point: CGPoint, bounds: CGRect, cell: CGSize, cols: Int, rows: Int
    ) -> (col: Int, row: Int)? {
        guard cell.width > 0, cell.height > 0 else { return nil }
        let col = Int(point.x / cell.width)
        let row = Int((bounds.height - point.y) / cell.height)
        guard (0..<cols).contains(col), (0..<rows).contains(row) else { return nil }
        return (col, row)
    }
}
