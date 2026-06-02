import AppKit
import SwiftTerm

/// Owns one live terminal per workroom for the lifetime of the app session, so that
/// switching workrooms hides/shows terminals instead of tearing them down — a running
/// dev server in workroom A survives while you look at B (decision D2). Cross-relaunch
/// disk persistence is intentionally out of scope.
@MainActor
final class TerminalSessions {
    private var views: [Workroom.ID: LocalProcessTerminalView] = [:]

    /// Returns the cached terminal for a workroom, creating and starting a login shell
    /// in its directory on first use.
    func view(for workroom: Workroom) -> LocalProcessTerminalView {
        if let existing = views[workroom.id] {
            return existing
        }
        let term = LocalProcessTerminalView(frame: .zero)

        let shell = ShellEnvironment.loginShell()
        let shellName = (shell as NSString).lastPathComponent
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        env.append("PATH=\(ShellEnvironment.path())")

        // `currentDirectory:` is present in the pinned SwiftTerm (v1.13.0).
        term.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env,
            execName: "-\(shellName)",
            currentDirectory: workroom.path
        )

        views[workroom.id] = term
        return term
    }

    /// Terminates and forgets the terminal for a workroom (call on delete / when its
    /// directory disappears) so we don't leak login shells.
    func reap(_ id: Workroom.ID) {
        guard let term = views.removeValue(forKey: id) else { return }
        terminate(term)
    }

    func reapAll() {
        for id in Array(views.keys) {
            reap(id)
        }
    }

    private func terminate(_ term: LocalProcessTerminalView) {
        // SwiftTerm v1.13.0 exposes the child via `process`; terminate() sends SIGTERM to
        // the shell so we don't leak login shells on switch / delete / quit.
        if term.process?.running == true {
            term.process?.terminate()
        }
        term.removeFromSuperview()
    }
}
