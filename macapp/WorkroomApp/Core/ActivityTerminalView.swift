import AppKit
import SwiftTerm

/// A terminal that surfaces explicit attention signals — OSC 9/99/777 notification escape
/// sequences and the bell — via `onActivity`. Detection only: coalescing, focus-gating, and
/// posting all live downstream (`NotificationCenterStore` / `AppStore`).
///
/// Subclasses `ThemedTerminalView` (the app's themed terminal) so a terminal is themed AND
/// activity-aware — tab creation, ⌘1-9, copy-on-select, and link opening are untouched. OSC
/// handling uses SwiftTerm's public `registerOscHandler` (which buffers sequences split across
/// PTY reads for us); the bell uses the `open func bell(source:)` hook. Both fire on the main
/// queue (SwiftTerm's `LocalProcess` defaults its dispatch queue to main).
final class ActivityTerminalView: ThemedTerminalView {
  /// Invoked on the main thread when this terminal emits a notification-worthy signal. Set by
  /// `TerminalSessions`; captures only value-type ids (never the view), and is cleared on close.
  var onActivity: ((TerminalActivity) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    installNotificationHandlers()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    installNotificationHandlers()
  }

  private func installNotificationHandlers() {
    let terminal = getTerminal()
    // [weak self]: the Terminal (owned by this view) retains these closures, so a strong
    // capture would form a view → terminal → parser → closure → view retain cycle.
    for code in [9, 777, 99] {
      terminal.registerOscHandler(code: code) { [weak self] data in
        guard let activity = OSCNotification.parse(code: code, data) else { return }
        self?.onActivity?(activity)
      }
    }
  }

  override func bell(source: Terminal) {
    super.bell(source: source)  // preserve the audible/visual bell
    onActivity?(.bell)
  }
}
