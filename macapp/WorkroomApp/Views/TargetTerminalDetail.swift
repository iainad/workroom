import SwiftUI

/// The terminal body for one target — the ZStack of `WorkroomTerminalsView` plus its setup-log
/// overlay/dock (issue #23). Lifted out of `RootView.targetDetail` so the detail pane (Projects mode)
/// and each Workrooms-mode tab render identical terminal UI. Carries **no** navigation title or
/// toolbar — the caller owns that chrome (`RootView` at the split level; `WorkroomModeView` at the
/// window level, driven by the focused tab).
///
/// While a setup script runs (`log.blocking`), the log floats over the pane and the terminal is
/// withheld — `WorkroomTerminalsView` mounts (and its `.task` creates the first terminal) only once
/// the blocking log is dismissed. Only workrooms ever have a log; for a root, `logs[target.id]` is nil.
struct TargetTerminalDetail: View {
  let target: TerminalTarget
  /// When co-displayed in a workroom split (issue #23 follow-up), the action that removes this workroom
  /// from the split — forwarded to the tab strip's trailing control. nil (default) for a solo target.
  var onCloseWorkroomPane: (() -> Void)? = nil
  /// Whether this workroom pane is the focused one — gates terminal first-responder so a co-displayed
  /// non-focused workroom doesn't steal focus on mount (issue #23 follow-up). `true` for a solo target.
  var surfaceActive: Bool = true
  @EnvironmentObject var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isBlocking = store.logs[target.id]?.blocking == true
    ZStack {
      if !isBlocking {
        VStack(spacing: 0) {
          WorkroomTerminalsView(
            target: target, sessions: store.terminals, onCloseWorkroomPane: onCloseWorkroomPane,
            surfaceActive: surfaceActive)

          if let log = store.logs[target.id] {
            Divider()
            ScriptLogPanel(session: log) { store.logs[target.id] = nil }
          }
        }
      }

      if let log = store.logs[target.id], log.blocking {
        SetupOverlay(session: log) {
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            store.logs[target.id] = nil
          }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        .zIndex(1)

        // While the setup script blocks, the terminals view (and so its tab-strip ✕) is withheld —
        // a split member mid-setup would otherwise be stuck in the split. Surface the
        // remove-from-split control in the corner, above the overlay, so the pane can still leave
        // the split (issue #23 follow-up; the strip handles the non-blocking empty case).
        if let onCloseWorkroomPane {
          CloseWorkroomPaneButton(action: onCloseWorkroomPane)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .zIndex(2)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
