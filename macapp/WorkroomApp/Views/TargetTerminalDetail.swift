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
  @EnvironmentObject var store: AppStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isBlocking = store.logs[target.id]?.blocking == true
    ZStack {
      if !isBlocking {
        VStack(spacing: 0) {
          WorkroomTerminalsView(target: target, sessions: store.terminals)

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
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
