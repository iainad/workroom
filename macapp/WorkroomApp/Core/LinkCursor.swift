import AppKit

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
/// Link detection lives in `TerminalLinks` (shared with `TerminalLinkOpener`).
@MainActor
enum LinkCursor {
    /// Whether *we* last forced the pointing-hand cursor. We only restore the I-beam when we
    /// were the one who changed it, so we never stomp on cursors owned by other views.
    private static var pointerActive = false

    /// Re-evaluate the cursor for the current pointer location and modifier state. Cheap and
    /// idempotent — safe to call on every mouse-moved / flags-changed event.
    static func update() {
        let terminal = TerminalLinks.terminalUnderMouse()
        if let terminal,
           NSEvent.modifierFlags.contains(.command),
           TerminalLinks.linkUnderMouse(in: terminal) != nil {
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
}
