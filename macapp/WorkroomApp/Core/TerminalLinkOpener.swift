import AppKit
import Darwin
import SwiftTerm

/// ⌘-clicking a *file path* in a terminal opens it in its default app — what double-clicking
/// the file in Finder does (`open <path>`). Web URLs keep SwiftTerm's default behaviour (open via
/// `NSWorkspace`). SwiftTerm makes links clickable only with ⌘ held (see `LinkCursor`), and its
/// own `requestOpenLink` would hand every link — paths included — to `NSWorkspace.open`, which
/// does nothing useful for a *bare path* (no scheme). So we intercept the ⌘-click in
/// `AppDelegate`'s `.leftMouseUp` monitor (the same pattern as `CopyOnSelect`, since SwiftTerm's
/// `mouseUp`/`requestOpenLink` aren't open to override): for a real file path we resolve it
/// against the shell's working directory and `open` it, then report `true` so the caller consumes
/// the event and SwiftTerm doesn't double-handle it. Everything else returns `false` and falls
/// through unchanged.
enum TerminalLinkOpener {
    /// Web URL schemes we leave to SwiftTerm's default (browser/mail) handling.
    private static let passthroughSchemes = [
        "http://", "https://", "ftp://", "ssh://", "git://",
        "mailto:", "tel:", "magnet:", "ipfs://", "ipns://", "gemini://", "gopher://", "news:",
    ]

    /// Handle a ⌘+left-click. Returns true iff we opened a file (so the caller consumes the event).
    static func handleCommandClick(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let terminal = TerminalLinks.terminalUnderMouse(),
              let link = TerminalLinks.linkUnderMouse(in: terminal),
              let path = filePath(from: link) else { return false }
        let cwd = workingDirectory(ofShell: terminal.process?.shellPid)
        guard let resolved = absolutePath(for: path, cwd: cwd),
              FileManager.default.fileExists(atPath: resolved) else { return false }
        openFile(resolved)
        return true
    }

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

    /// Open `path` in its default application via `/usr/bin/open` — equivalent to double-clicking
    /// it in Finder. Fire-and-forget.
    ///
    /// Security: `path` is passed as a literal argv element to `open` — never handed to a shell,
    /// so a maliciously-named file (e.g. `a$(touch x).txt`, which filenames may legally contain)
    /// can't be re-parsed into a command. We use the `open` CLI rather than `NSWorkspace.open(_:)`
    /// because the latter returns a bare `-50` for some files.
    private static func openFile(_ path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [path]
        do { try task.run() } catch { NSLog("Workroom: failed to open \(path): \(error)") }
    }

    /// The current working directory of shell `pid`, queried from the kernel (no OSC 7 needed —
    /// the login shells we spawn don't emit it). nil if the pid is gone or the query fails.
    private static func workingDirectory(ofShell pid: pid_t?) -> String? {
        guard let pid, pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
