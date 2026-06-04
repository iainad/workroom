import AppKit

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

  /// Open `path` (a workroom directory) in this editor.
  func open(_ path: String) {
    NSWorkspace.shared.open(
      [URL(fileURLWithPath: path)],
      withApplicationAt: appURL,
      configuration: NSWorkspace.OpenConfiguration()
    )
  }
}
