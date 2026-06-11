import SwiftUI

/// Per-project settings (issue #7): the run command + whether it auto-runs after a workroom is
/// created. Opened from the project row's context menu. Uses a draft + Cancel/Save model (unlike the
/// app `SettingsView`, which writes live) because a run command is a deliberate value you may get
/// wrong mid-typing. Styled like `SettingsView` (grouped form, fixed width) so it feels native.
struct ProjectSettingsSheet: View {
  let project: Project
  @EnvironmentObject var store: AppStore
  @Environment(\.dismiss) private var dismiss

  // Draft state, seeded from the store on appear; committed only on Save.
  @State private var command = ""
  @State private var autoRun = false

  /// Trim with the same set `RunConfig.hasCommand` uses, so the auto-run gate and what's actually
  /// runnable agree (a newlines-only command must read as blank too — review #7).
  private var commandIsBlank: Bool {
    command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField("Run command", text: $command, prompt: Text("e.g. npm run dev"))
            .lineLimit(1)
            .accessibilityIdentifier("projectSettings.runCommand")
          Toggle("Run automatically when a workroom is created", isOn: $autoRun)
            // Disabled — and forced back off — when there's no command, so Save can't persist a dead
            // `RunConfig(command: "", autoRun: true)` that never runs (review #7).
            .disabled(commandIsBlank)
            .onChange(of: command) { _ in if commandIsBlank { autoRun = false } }
            .accessibilityIdentifier("projectSettings.autoRun")
        } header: {
          Text("Run Command")
        } footer: {
          Text(
            "Runs in a dedicated terminal at the workroom's directory, in your login shell. "
              + "Start it from the toolbar Run button or ⌘R.")
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          store.setRunConfig(
            RunConfig(command: command, autoRun: autoRun), forProject: project.path)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
      }
      .padding()
    }
    .frame(width: 460)
    .onAppear {
      let config = store.runConfig(forProject: project.path)
      command = config.command
      autoRun = config.autoRun
    }
  }
}
