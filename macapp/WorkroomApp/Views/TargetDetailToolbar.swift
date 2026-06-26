import AppKit
import Defaults
import SwiftUI

/// The "Open in…" editor control for a selected target: a menu whose primary action reopens in the
/// last-picked editor. A plain `View` (not `ToolbarContent`) so it composes into the title-bar
/// toolbar (`TrailingTitlebarBar`) as a sibling of the other controls, sharing its `.borderless`
/// button style. (Renders nothing when no editors are installed.)
struct OpenInControl: View {
  let path: String

  /// Bundle id of the last editor picked from the "Open in…" menu — the primary action reopens in it.
  @Default(.lastEditor) private var lastEditorID

  var body: some View {
    let editors = ExternalEditor.installed
    if !editors.isEmpty {
      let remembered = editors.first { $0.id == lastEditorID } ?? editors[0]
      // Two SEPARATE controls in one tight group: an icon Button that opens in the remembered editor
      // on a single click (also ⇧⌘O / the Go-menu item), and a chevron Menu to pick a different one.
      // Both inherit the bar's `ToolbarIconButtonStyle`, so each gets its own hover well. Negative
      // spacing pulls the two 22pt-min wells together so the small chevron sits snug against the icon
      // (each well only paints on its own hover, so the slight overlap never shows two at once).
      HStack(spacing: -8) {
        Button {
          remembered.open(path)
        } label: {
          Image(systemName: "arrow.up.forward.app")
            .hidden()
            .overlay {
              Image(nsImage: remembered.icon).renderingMode(.original).resizable().scaledToFit()
            }
            .frame(width: 16, height: 16)
        }
        .help("Open in \(remembered.name) (⇧⌘O)")
        .accessibilityLabel("Open in \(remembered.name)")

        Menu {
          ForEach(editors) { editor in
            Button {
              lastEditorID = editor.id
              editor.open(path)
            } label: {
              Label {
                Text(editor.name)
              } icon: {
                Image(nsImage: editor.icon).renderingMode(.original)
              }
            }
          }
        } label: {
          Image(systemName: "chevron.down")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        // We draw the chevron ourselves, so hide the system disclosure indicator.
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open in… (choose editor)")
        .accessibilityLabel("Choose editor")
      }
    }
  }
}

/// The run-command controls for a selected workroom (issue #7): a Run button that becomes Stop +
/// Restart while the command is running. Renders nothing when the project has no run command
/// configured (no disabled ghost). Reads run-state straight off `AppStore` — `@EnvironmentObject`
/// re-evaluates on `@Published` changes, so the toggle flips live (OV-A). A plain `View` (not
/// `ToolbarContent`) so it composes into the title-bar toolbar (`TrailingTitlebarBar`).
struct RunControls: View {
  let target: TerminalTarget
  /// The owning project's path — used to look up the configured command (`hasRunCommand`).
  let projectPath: String
  @EnvironmentObject var store: AppStore

  var body: some View {
    if store.canRunCommand(for: target, inProject: projectPath) {
      if store.isRunCommandRunning(for: target.id) {
        Button {
          store.stopRunCommand(for: target)
        } label: {
          Image(systemName: "stop.fill")
        }
        .help("Stop the run command (⇧⌘R) — again to force-quit")
        .accessibilityLabel("Stop")
        .accessibilityIdentifier("runCommand.stop")

        Button {
          store.restartRunCommand(for: target)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Restart the run command (⌥⌘R)")
        .accessibilityLabel("Restart")
        .accessibilityIdentifier("runCommand.restart")
      } else {
        // Not running (no run tab, or stopped-but-open). `runOrFocusRunCommand` acts on the
        // selection — which is this target — so it starts, or re-runs a stopped pane (OV-B).
        Button {
          store.runOrFocusRunCommand()
        } label: {
          Image(systemName: "play.fill")
        }
        .help("Run the project command (⌘R)")
        .accessibilityLabel("Run")
        .accessibilityIdentifier("runCommand.run")
      }
    }
  }
}
