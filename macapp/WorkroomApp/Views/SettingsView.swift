import SwiftUI

/// The app's Settings window (⌘,). Consolidates the preferences that previously lived in the
/// Edit and View menus. Each control binds the *same* `@AppStorage` key its old menu item used,
/// so the stored value — and everything observing it (appearance application in `RootView`,
/// copy-on-select, ⌘-click file opening) — is unchanged; only the surface moves here.
struct SettingsView: View {
  @AppStorage(ThemePreference.storageKey) private var theme: ThemePreference = .system
  @AppStorage(CopyOnSelect.storageKey) private var copyOnSelect = true
  @AppStorage(ConfirmOnQuit.storageKey) private var confirmOnQuit = true
  // Bundle id of the editor for ⌘-clicked file paths; "" = the file's default app.
  @AppStorage(TerminalLinkOpener.editorStorageKey) private var pathEditor = ""
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
