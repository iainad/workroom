import AppKit
import Defaults

/// An installed app that can open a workroom directory, offered in the detail toolbar's
/// "Open in…" menu. Only the supported editors that are actually installed appear.
struct ExternalEditor: Identifiable {
  let id: String  // bundle identifier
  let name: String
  let appURL: URL

  /// Supported editors (bundle id + display name), in menu order.
  private static let supported: [(id: String, name: String)] = [
    ("com.microsoft.VSCode", "Visual Studio Code"),
    ("dev.zed.Zed", "Zed"),
    ("com.apple.dt.Xcode", "Xcode"),
  ]

  /// The supported editors currently installed, resolved to their app bundle URLs.
  static var installed: [ExternalEditor] {
    supported.compactMap { editor in
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.id) else {
        return nil
      }
      return ExternalEditor(id: editor.id, name: editor.name, appURL: url)
    }
  }

  /// The editor the primary "Open in" action uses: the one last picked (`Defaults[.lastEditor]`), else
  /// the first installed. nil when none are installed. Single source for the toolbar's open button, the
  /// ⌘O command, and the Go-menu item, so they always target the same editor.
  static var remembered: ExternalEditor? {
    let installed = installed
    return installed.first { $0.id == Defaults[.lastEditor] } ?? installed.first
  }

  /// The editor configured for opening *file paths* (Settings → "Open file paths in",
  /// `Defaults[.filePathEditor]`), or nil when unset — i.e. the file's default app. Names the
  /// Changes-panel "Open file in…" action (issue #93). Unlike `remembered`, this never falls back to
  /// the first installed editor: an unset/uninstalled choice deliberately reads as "default app".
  static var forFilePaths: ExternalEditor? {
    let id = Defaults[.filePathEditor]
    return id.isEmpty ? nil : installed.first { $0.id == id }
  }

  /// The app's Finder icon, sized for inline display beside its name in the
  /// "Open in…" button and menu.
  var icon: NSImage {
    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
    icon.size = NSSize(width: 20, height: 20)
    return icon
  }

  /// Open `path` (a workroom directory) in this editor.
  func open(_ path: String) {
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path)],
      withApplicationAt: appURL,
      configuration: NSWorkspace.OpenConfiguration()
    )
  }
}
