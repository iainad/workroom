import AppKit
import Defaults
import SwiftUI

/// The detail pane's toolbar for a selected target: an "Open in…" editor menu (whose primary
/// action reopens in the last-picked editor), Reveal in Finder, and Copy Path. Lifted out of
/// `RootView.targetDetail` so the scene root stays focused on layout. (The notifications bell
/// lives beside back/forward in `RootView`'s split-view toolbar so it shows even with no target.)
struct TargetDetailToolbar: ToolbarContent {
  let path: String

  /// Bundle id of the last editor picked from the "Open in…" menu — the toolbar button's
  /// primary action reopens in it.
  @Default(.lastEditor) private var lastEditorID

  var body: some ToolbarContent {
    ToolbarItemGroup {
      let editors = ExternalEditor.installed
      if !editors.isEmpty {
        // Primary action reopens in the remembered editor; the menu switches it.
        let remembered = editors.first { $0.id == lastEditorID } ?? editors[0]
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
          Label {
            Text("Open in…")
          } icon: {
            // The toolbar auto-scales SF Symbols but renders a bitmap at its own size, so
            // fit the app icon into a hidden reference symbol to match the other toolbar icons.
            Image(systemName: "arrow.up.forward.app")
              .hidden()
              .overlay {
                Image(nsImage: remembered.icon).renderingMode(.original).resizable().scaledToFit()
              }
          }
        } primaryAction: {
          remembered.open(path)
        }
        .help("Open in \(remembered.name)")
      }

      Button {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
      } label: {
        Label("Reveal in Finder", systemImage: "folder")
      }
      .help("Reveal in Finder")

      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
      } label: {
        Label("Copy Path", systemImage: "doc.on.doc")
      }
      .help("Copy path")
    }
  }
}

/// The run-command controls for a selected workroom (issue #7): a Run button that becomes Stop +
/// Restart while the command is running. Renders nothing when the project has no run command
/// configured (no disabled ghost). Reads run-state straight off `AppStore` — a `ToolbarContent` with
/// an `@EnvironmentObject` re-evaluates on `@Published` changes (unlike a `Commands` body), so the
/// toggle flips live (OV-A). Attached only for `.workroom` selections.
struct RunCommandToolbar: ToolbarContent {
  let target: TerminalTarget
  /// The owning project's path — used to look up the configured command (`hasRunCommand`).
  let projectPath: String
  @EnvironmentObject var store: AppStore

  var body: some ToolbarContent {
    ToolbarItemGroup {
      if store.canRunCommand(for: target, inProject: projectPath) {
        if store.isRunCommandRunning(for: target.id) {
          Button {
            store.stopRunCommand(for: target)
          } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .help("Stop the run command (again to force-quit)")
          .accessibilityIdentifier("runCommand.stop")

          Button {
            store.restartRunCommand(for: target)
          } label: {
            Label("Restart", systemImage: "arrow.clockwise")
          }
          .help("Restart the run command")
          .accessibilityIdentifier("runCommand.restart")
        } else {
          // Not running (no run tab, or stopped-but-open). `runOrFocusRunCommand` acts on the
          // selection — which is this target — so it starts, or re-runs a stopped pane (OV-B).
          Button {
            store.runOrFocusRunCommand()
          } label: {
            Label("Run", systemImage: "play.fill")
          }
          .help("Run the project command")
          .accessibilityIdentifier("runCommand.run")
        }
      }
    }
  }
}
