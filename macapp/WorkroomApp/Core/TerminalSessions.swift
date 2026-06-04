import AppKit
import SwiftTerm

/// One terminal tab: a live shell view plus a stable id and title for the tab strip.
struct TerminalTab: Identifiable {
    let id = UUID()
    let view: LocalProcessTerminalView
    let title: String
}

/// Owns the live terminals for each workroom — one or more tabs per workroom — for the
/// lifetime of the app session, so switching workrooms or tabs hides/shows terminals
/// instead of tearing them down (a running dev server in one tab survives while you look
/// at another). Cross-relaunch disk persistence is intentionally out of scope.
@MainActor
final class TerminalSessions: ObservableObject {
    @Published private var tabsByWorkroom: [Workroom.ID: [TerminalTab]] = [:]
    @Published private var activeByWorkroom: [Workroom.ID: TerminalTab.ID] = [:]
    /// Per-workroom running counter so tab titles ("Terminal 1", "2", …) stay stable
    /// across closes rather than renumbering.
    private var counts: [Workroom.ID: Int] = [:]

    func tabs(for workroom: Workroom) -> [TerminalTab] {
        tabsByWorkroom[workroom.id] ?? []
    }

    func activeTab(for workroom: Workroom) -> TerminalTab? {
        let tabs = tabsByWorkroom[workroom.id] ?? []
        if let id = activeByWorkroom[workroom.id], let match = tabs.first(where: { $0.id == id }) {
            return match
        }
        return tabs.first
    }

    /// Create the workroom's first terminal the first time its pane appears. Once it has
    /// been opened, an emptied tab set is left as-is (the user closed them on purpose).
    func ensureTab(for workroom: Workroom) {
        if tabsByWorkroom[workroom.id] == nil {
            addTab(for: workroom)
        }
    }

    func addTab(for workroom: Workroom) {
        let count = (counts[workroom.id] ?? 0) + 1
        counts[workroom.id] = count
        let tab = TerminalTab(view: makeTerminal(for: workroom), title: "Terminal \(count)")
        tabsByWorkroom[workroom.id, default: []].append(tab)
        activeByWorkroom[workroom.id] = tab.id
    }

    func select(_ tabID: TerminalTab.ID, for workroom: Workroom) {
        activeByWorkroom[workroom.id] = tabID
    }

    /// Reorder (drag-and-drop in the tab bar): move the dragged tab to `index` in the tab
    /// order. `index` is interpreted against the array *after* the dragged tab is removed,
    /// and is clamped to bounds. The active tab is unaffected.
    func moveTab(_ draggedID: TerminalTab.ID, toIndex index: Int, for workroom: Workroom) {
        guard var tabs = tabsByWorkroom[workroom.id],
              let from = tabs.firstIndex(where: { $0.id == draggedID }) else { return }
        let moved = tabs.remove(at: from)
        tabs.insert(moved, at: max(0, min(index, tabs.count)))
        tabsByWorkroom[workroom.id] = tabs
    }

    /// Close a tab. Closing the last one leaves the workroom with no terminals — the tab
    /// bar (and its add button) stays, and the active tab becomes nil.
    func closeTab(_ tabID: TerminalTab.ID, for workroom: Workroom) {
        guard var tabs = tabsByWorkroom[workroom.id],
              let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let removed = tabs.remove(at: idx)
        terminate(removed.view)
        tabsByWorkroom[workroom.id] = tabs
        if activeByWorkroom[workroom.id] == tabID {
            // Activate the neighbour that slid into this slot, else the new last tab
            // (nil when none remain).
            activeByWorkroom[workroom.id] = (idx < tabs.count ? tabs[idx] : tabs.last)?.id
        }
    }

    /// Terminate and forget every terminal for a workroom (on delete / when its directory
    /// disappears) so we don't leak login shells.
    func reap(_ id: Workroom.ID) {
        for tab in tabsByWorkroom[id] ?? [] { terminate(tab.view) }
        tabsByWorkroom[id] = nil
        activeByWorkroom[id] = nil
        counts[id] = nil
    }

    func reapAll() {
        for id in Array(tabsByWorkroom.keys) { reap(id) }
    }

    private func makeTerminal(for workroom: Workroom) -> LocalProcessTerminalView {
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
        return term
    }

    private func terminate(_ term: LocalProcessTerminalView) {
        // SwiftTerm v1.13.0 exposes the child via `process`; terminate() sends SIGTERM to
        // the shell so we don't leak login shells on switch / close / delete / quit.
        if term.process?.running == true {
            term.process?.terminate()
        }
        term.removeFromSuperview()
    }
}
