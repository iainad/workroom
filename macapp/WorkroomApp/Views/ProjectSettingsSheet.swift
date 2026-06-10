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

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          TextField("Run command", text: $command, prompt: Text("e.g. npm run dev"))
            .lineLimit(1)
            .accessibilityIdentifier("projectSettings.runCommand")
          Toggle("Run automatically when a workroom is created", isOn: $autoRun)
            .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
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
