import AppKit
import SwiftUI

/// Hosts the selected workroom's terminal. Switching swaps which cached terminal is
/// mounted in the container; unmounted terminals stay alive in `TerminalSessions`
/// (retained, just detached from the view hierarchy) so their shells keep running.
struct TerminalContainerView: NSViewRepresentable {
  let workroom: Workroom
  let sessions: TerminalSessions

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
    let term = sessions.view(for: workroom)
    if term.superview === container { return }

    // Detach whatever was shown (do NOT terminate — it lives on in the cache).
    for sub in container.subviews {
      sub.removeFromSuperview()
    }

    term.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(term)
    NSLayoutConstraint.activate([
      term.topAnchor.constraint(equalTo: container.topAnchor),
      term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      term.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    DispatchQueue.main.async { container.window?.makeFirstResponder(term) }
  }
}
