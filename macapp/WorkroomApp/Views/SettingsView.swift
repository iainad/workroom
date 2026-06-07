import Defaults
import SwiftUI

/// The app's Settings window (⌘,). Consolidates the preferences that previously lived in the
/// Edit and View menus. Each control binds the *same* `Defaults` key its old menu item used,
/// so the stored value — and everything observing it (appearance application in `RootView`,
/// copy-on-select, ⌘-click file opening) — is unchanged; only the surface moves here.
struct SettingsView: View {
  @Default(.theme) private var theme
  @Default(.copyOnSelect) private var copyOnSelect
  @Default(.confirmOnQuit) private var confirmOnQuit
  @Default(.confirmOnCloseTerminal) private var confirmOnCloseTerminal
  @Default(.globalHotkey) private var globalHotkey
  // Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  @Default(.filePathEditor) private var pathEditor
  @EnvironmentObject private var updater: Updater

  var body: some View {
    Form {
      Picker("Appearance", selection: $theme) {
        ForEach(ThemePreference.allCases, id: \.self) { pref in
          Text(pref.label).tag(pref)
        }
      }

      Toggle("Copy on select", isOn: $copyOnSelect)

      Toggle("Confirm before quitting", isOn: $confirmOnQuit)

      Toggle("Confirm before closing a terminal", isOn: $confirmOnCloseTerminal)

      Toggle("Global show/hide hotkey (⌘§)", isOn: $globalHotkey)

      Picker("Open file paths in", selection: $pathEditor) {
        Text("Default App").tag("")
        ForEach(ExternalEditor.installed) { editor in
          Text(editor.name).tag(editor.id)
        }
      }

      // Drives Sparkle's scheduled background checks (persisted as SUEnableAutomaticChecks).
      Toggle(
        "Automatically check for updates",
        isOn: Binding(
          get: { updater.automaticallyChecksForUpdates },
          set: { updater.automaticallyChecksForUpdates = $0 }))
    }
    .formStyle(.grouped)
    .frame(width: 440)
  }
}
