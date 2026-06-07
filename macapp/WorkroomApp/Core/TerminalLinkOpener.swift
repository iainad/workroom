import AppKit
import Defaults

/// ⌘-clicking a *file path* in a terminal opens it in the editor chosen in the "Open File Paths In"
/// menu — by default the file's default app (`open <path>`), or a specific editor
/// (`open -b <bundleID> <path>`). Web URLs open via `NSWorkspace`. Driven by `GhosttySurfaceView`'s
/// ⌘-click (for bare paths) and libghostty's open-URL action; relative paths resolve against the
/// surface's `GHOSTTY_ACTION_PWD`-tracked cwd (see plan CMT-1).
enum TerminalLinkOpener {
  /// Web URL schemes we leave to the browser/mail handler (not treated as file paths).
  private static let passthroughSchemes = [
    "http://", "https://", "ftp://", "ssh://", "git://",
    "mailto:", "tel:", "magnet:", "ipfs://", "ipns://", "gemini://", "gopher://", "news:",
  ]

  /// The filesystem path a link refers to, or nil if it's a web URL we don't open ourselves.
  static func filePath(from link: String) -> String? {
    if passthroughSchemes.contains(where: { link.hasPrefix($0) }) { return nil }
    if link.hasPrefix("file:") { return URL(string: link)?.path }
    return link
  }

  /// Resolve `path` (absolute, ~-relative, or cwd-relative) to an absolute path. Returns nil
  /// for a relative path when the working directory is unknown.
  static func absolutePath(for path: String, cwd: String?) -> String? {
    if path.hasPrefix("/") { return path }
    if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
    guard let cwd else { return nil }
    return (cwd as NSString).appendingPathComponent(path)
  }

  /// Open `path` via `/usr/bin/open` — in the chosen editor, or the file's default app
  /// (double-click-in-Finder behaviour) when none is set. Fire-and-forget.
  ///
  /// Security: `path` is passed as a literal argv element to `open` — never handed to a shell,
  /// so a maliciously-named file (e.g. `a$(touch x).txt`, which filenames may legally contain)
  /// can't be re-parsed into a command. We use the `open` CLI rather than `NSWorkspace.open(_:)`
  /// because the latter returns a bare `-50` for some files.
  private static func openFile(_ path: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = openArguments(path: path, editorBundleID: Defaults[.filePathEditor])
    do { try task.run() } catch { NSLog("Workroom: failed to open \(path): \(error)") }
  }

  /// `open` argv: `-b <bundleID> <path>` when `editorBundleID` names an installed app, else just
  /// `<path>` (the file's default app). Falls back to the default app if the chosen editor was
  /// since uninstalled. The bundle id comes from our own picker and `path` is a literal argv
  /// element, so neither is shell-interpreted.
  static func openArguments(path: String, editorBundleID: String?) -> [String] {
    if let id = editorBundleID, !id.isEmpty,
      NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    {
      return ["-b", id, path]
    }
    return [path]
  }

  // MARK: libghostty entry points (cwd from GHOSTTY_ACTION_PWD — CMT-1)

  /// ⌘-clicked a bare word (from `ghostty_surface_quicklook_word`) that resolves to a real file →
  /// open it in the configured editor. No-op if it doesn't resolve (e.g. cwd unknown for a relative
  /// path under ssh/tmux — see plan CMT-1).
  static func handleCmdClickFile(_ word: String, cwd: String?) {
    guard let resolved = resolveExistingFile(word, cwd: cwd) else { return }
    openFile(resolved)
  }

  /// Does `word` resolve to an existing file? Drives the ⌘-hover pointing-hand cursor affordance.
  static func resolvesToFile(_ word: String, cwd: String?) -> Bool {
    resolveExistingFile(word, cwd: cwd) != nil
  }

  /// Handle libghostty's `GHOSTTY_ACTION_OPEN_URL`: open local files/paths in the configured editor,
  /// web URLs via `NSWorkspace`. Returns true (we are the apprt — always handle, since there's no
  /// engine-side fallback).
  static func handleOpenURL(_ url: URL, cwd: String?) -> Bool {
    if let resolved = resolveLocalFile(from: url, cwd: cwd) {
      openFile(resolved)
    } else {
      NSWorkspace.shared.open(url)
    }
    return true
  }

  /// Resolve `word` (absolute, ~-relative, or cwd-relative) to an existing, non-passthrough file path.
  private static func resolveExistingFile(_ word: String, cwd: String?) -> String? {
    guard let path = filePath(from: word),
      let abs = absolutePath(for: path, cwd: cwd),
      FileManager.default.fileExists(atPath: abs)
    else { return nil }
    return abs
  }

  /// A local file path from a libghostty open-URL, or nil for a real (schemed) web URL.
  private static func resolveLocalFile(from url: URL, cwd: String?) -> String? {
    if url.isFileURL {
      let path = url.path
      return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    guard url.scheme == nil else { return nil }  // http/https/etc. → not a local file
    return resolveExistingFile(
      url.absoluteString.removingPercentEncoding ?? url.absoluteString, cwd: cwd)
  }

}
