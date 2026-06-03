import AppKit
import SwiftTerm
import SwiftUI

/// Hosts a single terminal view, clipped to rounded corners. Terminals live in
/// `TerminalSessions` (retained across switches); this view just mounts whichever one
/// it's given and re-mounts when that changes.
struct TerminalContainerView: NSViewRepresentable {
  let terminal: LocalProcessTerminalView

  func makeNSView(context: Context) -> NSView {
    let container = NSView()
    container.wantsLayer = true
    // Round the terminal's corners. masksToBounds clips the hosted AppKit terminal
    // (pinned to the container edges) to the rounded shape.
    container.layer?.cornerRadius = 12
    container.layer?.cornerCurve = .continuous
    container.layer?.masksToBounds = true
    mount(in: container)
    return container
  }

  func updateNSView(_ container: NSView, context: Context) {
    mount(in: container)
  }

  private func mount(in container: NSView) {
    if terminal.superview === container { return }

    // Detach whatever was shown (do NOT terminate — it lives on in the cache).
    for sub in container.subviews {
      sub.removeFromSuperview()
    }

    terminal.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(terminal)
    NSLayoutConstraint.activate([
      terminal.topAnchor.constraint(equalTo: container.topAnchor),
      terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    DispatchQueue.main.async { container.window?.makeFirstResponder(terminal) }
  }
}
