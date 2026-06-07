import AppKit
import SwiftUI

/// Persists the `NavigationSplitView`'s user-dragged column widths (the sidebar in particular)
/// across launches by giving the underlying AppKit `NSSplitView` a stable autosave name. SwiftUI
/// exposes no width binding, so we locate the split view from a zero-size probe placed in the
/// sidebar and let `NSSplitView`'s built-in autosave save + restore the divider positions.
/// (Issue #14 — sidebar width.)
struct SplitViewAutosave: NSViewRepresentable {
  let name: String

  func makeNSView(context: Context) -> NSView {
    let probe = NSView(frame: .zero)
    // The split view doesn't exist in the hierarchy until the probe is mounted in the window;
    // hop a runloop, then walk up to the nearest enclosing NSSplitView and name it once.
    DispatchQueue.main.async { [weak probe] in
      var view = probe?.superview
      while let current = view, !(current is NSSplitView) { view = current.superview }
      if let split = view as? NSSplitView, split.autosaveName != name {
        split.autosaveName = name
      }
    }
    return probe
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}
