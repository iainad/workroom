import AppKit
import SwiftUI

/// Hosts a single terminal surface, clipped to rounded corners. Terminals live in
/// `TerminalSessions` (retained across switches); this view mounts whichever one it's given and
/// re-mounts when that changes.
///
/// Occlusion (plan A4): the hosted surface is marked visible on mount and **hidden on dismantle**,
/// so a backgrounded tab's GPU surface stops rendering while it stays alive (its shell keeps running).
/// With splits (issue #3) the model also drives occlusion centrally (`reconcileOcclusion`), so several
/// panes can be visible at once; this view's mount/dismantle is the per-mount backstop.
///
/// This hosts exactly one terminal surface (one tab). A split composes several of these into one
/// on-screen layout via the recursive pane renderer over `PaneLayout` — splitting does not nest
/// surfaces inside a tab.
///
/// Focus (issue #3): with multiple panes mounted, only the focused one may grab first responder.
/// `isFocusedPane` drives that — the host passes `true` for exactly the focused leaf. Mount no longer
/// force-focuses unconditionally (that would let the last-mounted pane steal focus); focus is applied
/// from `isFocusedPane` on update. A pane the user clicks becomes first responder via the surface's own
/// `mouseDown`, which feeds the selection back through `onFocused`.
struct TerminalContainerView: NSViewRepresentable {
  let view: GhosttySurfaceView
  /// Whether this pane should hold keyboard focus. Solo callers leave it `true`; the split renderer
  /// passes `true` only for the focused leaf.
  var isFocusedPane: Bool = true

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    // Round the terminal's corners. masksToBounds clips the hosted surface (pinned to the
    // container edges) to the rounded shape.
    container.layer?.cornerRadius = 12
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    mount(in: container)
    applyFocus(in: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    mount(in: container)
    applyFocus(in: container)
  }

  // No `dismantleNSView`: occlusion is driven by the model (`reconcileOcclusion`) and by AppKit's
  // window occlusion (a surface removed from the window pauses via `viewDidMoveToWindow`). Pausing here
  // on dismantle would be redundant and, worse, would race the split↔solo transition — when a split
  // collapses, the surviving surface is re-homed from the (dismantled) split leaf into the solo
  // container, and a stray `setVisible(false)` landing after the re-home left the pane blank (issue #3).

  private func mount(in container: NSView) {
    if view.superview === container {
      view.frame = container.bounds
      view.setVisible(true)
      return
    }
    // Detach whatever was shown (do NOT tear down — it lives on in the cache).
    for sub in container.subviews { sub.removeFromSuperview() }

    // Pin the surface to the container with an autoresizing mask, NOT AutoLayout constraints. A surface
    // is re-homed between containers (split leaf → solo, and back) while the old container may still be
    // alive mid-transition; AutoLayout constraints to the old container would linger and conflict with
    // the new ones, leaving the surface at a broken/zero frame (a blank pane — issue #3). A frame +
    // autoresizing mask carries no cross-container state, so re-homing is clean.
    view.translatesAutoresizingMaskIntoConstraints = true
    view.frame = container.bounds
    view.autoresizingMask = [.width, .height]
    container.addSubview(view)
    view.setVisible(true)
  }

  /// Make the focused pane first responder, but only when it isn't already (so re-rendering a focused
  /// solo pane, or a divider drag, doesn't churn the responder chain). Never steals focus for a
  /// non-focused pane.
  private func applyFocus(in container: NSView) {
    guard isFocusedPane else { return }
    DispatchQueue.main.async {
      guard let window = container.window, window.firstResponder !== view else { return }
      window.makeFirstResponder(view)
    }
  }
}
