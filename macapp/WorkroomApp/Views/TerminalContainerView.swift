import AppKit
import SwiftUI

/// Hosts a single terminal surface, clipped to rounded corners. Terminals live in
/// `TerminalSessions` (retained across switches); this view mounts whichever one it's given and
/// re-mounts when that changes.
///
/// Occlusion (plan A4): the hosted surface is marked visible on mount and **hidden on dismantle**,
/// so a backgrounded tab's GPU surface stops rendering while it stays alive (its shell keeps
/// running). Only the active tab's `TerminalContainerView` is mounted by `WorkroomTerminalsView`
/// (via `.id(active.id)`), so mount/dismantle tracks active-tab changes.
///
/// Today a tab is a single leaf, so this hosts one surface. The splits feature (A5) will render the
/// full `PaneNode` tree here (libghostty supports splits at the surface level).
struct TerminalContainerView: NSViewRepresentable {
  let view: GhosttySurfaceView

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    // Round the terminal's corners. masksToBounds clips the hosted surface (pinned to the
    // container edges) to the rounded shape.
    container.layer?.cornerRadius = 12
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    mount(in: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    mount(in: container)
  }

  /// Tab switched away (or pane closed): stop the surface rendering while it lives on in the cache.
  static func dismantleNSView(_ container: NSView, coordinator: ()) {
    (container.subviews.compactMap { $0 as? GhosttySurfaceView }.first)?.setVisible(false)
  }

  private func mount(in container: NSView) {
    if view.superview === container {
      view.setVisible(true)
      return
    }
    // Detach whatever was shown (do NOT tear down — it lives on in the cache).
    for sub in container.subviews { sub.removeFromSuperview() }

    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
      view.topAnchor.constraint(equalTo: container.topAnchor),
      view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    view.setVisible(true)
    DispatchQueue.main.async { container.window?.makeFirstResponder(view) }
  }
}
