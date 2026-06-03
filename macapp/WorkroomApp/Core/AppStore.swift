import Foundation
import SwiftUI

/// Identifies a row in the unified project → workroom sidebar tree. Workroom names can
/// repeat across projects, so a workroom is identified by its project path plus name.
enum SidebarID: Hashable {
    case project(String)
    case workroom(project: String, name: String)
}

/// A workroom queued for deletion, awaiting the user's confirmation. Held on the store so
/// both the sidebar's delete affordances and the Delete menu command (⌘⌫) raise the same
/// confirmation prompt.
struct PendingWorkroomDeletion {
    let workroom: Workroom
    let project: Project
}

/// App-wide state and actions. A single shared instance is used so the App, views,
/// and menu Commands all act on the same store. All CLI work is awaited (it runs off
/// the main thread inside WorkroomCLI), keeping the UI responsive.
@MainActor
final class AppStore: ObservableObject {
    static let shared = AppStore()

    @Published var projects: [Project] = []
    @Published var selectedProjectID: Project.ID?
    @Published var selectedWorkroomID: Workroom.ID?

    @Published var errorMessage: String?
    /// Title for the error alert. Nil falls back to the generic title; specific
    /// failures (e.g. teardown) set their own.
    @Published var errorTitle: String?
    @Published var isLoading = false
    /// Project paths with an in-flight create/delete (for per-row progress + disabling).
    @Published var busyProjects: Set<String> = []
    /// Set by the "Add Project" menu command to trigger the sidebar's file importer.
    @Published var requestAddProject = false
    /// A workroom awaiting delete confirmation; setting it raises the confirmation prompt.
    @Published var pendingDeletion: PendingWorkroomDeletion?
    /// Setup logs scoped per workroom, rendered under that workroom's terminal. Kept
    /// until the user closes them (or the workroom is deleted) so the output stays
    /// available for review. Streaming starts as soon as the CLI reports the workroom
    /// exists (its early "created" event), before setup finishes.
    @Published var logs: [Workroom.ID: ScriptLogSession] = [:]

    let terminals = TerminalSessions()

    private init() {}

    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectID }
    }

    var selectedWorkroom: Workroom? {
        selectedProject?.workrooms.first { $0.id == selectedWorkroomID }
    }

    // MARK: Loading

    /// Initial launch: render config-only (instant, no VCS calls), then refresh warnings.
    func bootstrap() async {
        await load(warnings: "none")
        await load(warnings: "fast")
    }

    func reload() async {
        await load(warnings: "fast")
    }

    private func load(warnings: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await WorkroomCLI.shared.list(warnings: warnings)
            apply(response.projects)
        } catch {
            present(error)
        }
    }

    private func apply(_ fresh: [Project]) {
        projects = fresh
        // Keep selection valid; default to the first project / first workroom.
        if selectedProjectID == nil || !fresh.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = fresh.first?.id
        }
        if let project = selectedProject,
           selectedWorkroomID == nil || !project.workrooms.contains(where: { $0.id == selectedWorkroomID }) {
            selectedWorkroomID = nil
        }
    }

    // MARK: Mutations

    func addProject(_ url: URL) async {
        do {
            try await WorkroomCLI.shared.addProject(url.path)
            await reload()
            // Select the freshly added project.
            if let match = projects.first(where: { $0.path == url.path || ($0.path as NSString).lastPathComponent == url.lastPathComponent }) {
                selectedProjectID = match.id
                selectedWorkroomID = nil
            }
        } catch {
            present(error)
        }
    }

    func createWorkroom(in project: Project) async {
        busyProjects.insert(project.path)
        defer { busyProjects.remove(project.path) }

        let session = ScriptLogSession(title: "Setting up new workroom in \(project.displayName)", phase: "setup")
        do {
            let created = try await WorkroomCLI.shared.create(
                project: project.path,
                onLog: { text in
                    DispatchQueue.main.async { session.append(text) }
                },
                onReady: { name, _ in
                    // The workroom now exists; mount it and dock the streaming log under
                    // its terminal so setup output appears live from the start.
                    DispatchQueue.main.async {
                        Task { @MainActor in await self.mountSetupLog(session, workroom: name, project: project) }
                    }
                }
            )
            session.finish()
            await reload()
            // Mount now if the early "created" event never arrived (older CLI).
            if session.workroomID == nil { await mountSetupLog(session, workroom: created.name, project: project) }
            // A run with no output leaves nothing to dock.
            if session.lines.isEmpty { logs[created.name] = nil }
        } catch {
            // Even on (partial) failure, reload so a "created but setup failed" workroom shows up.
            await reload()
            if let name = session.workroomID {
                // The workroom exists; show the failure in its docked log.
                logs[name] = session
                selectedProjectID = project.id
                selectedWorkroomID = name
                session.finish(failure: errorText(error))
            } else {
                // Failed before the workroom existed — nothing to dock under.
                present(error)
            }
        }
    }

    /// Mounts a just-created workroom (selecting it so its terminal opens) and docks the
    /// setup log under it. Safe to call more than once.
    private func mountSetupLog(_ session: ScriptLogSession, workroom name: String, project: Project) async {
        session.workroomID = name
        logs[name] = session
        await reload()
        selectedProjectID = project.id
        selectedWorkroomID = name
    }

    /// Removes the workroom from the sidebar immediately, then runs its teardown (script +
    /// workspace removal) in the background. On success the optimistic removal already
    /// matches reality; on failure we reload (so it reappears if it still exists) and
    /// surface the error.
    func deleteWorkroom(_ workroom: Workroom, in project: Project) {
        // Optimistic: drop it from the model now, reap its terminals/log, clear selection.
        removeWorkroomLocally(workroom, in: project)
        terminals.reap(workroom.id)
        logs[workroom.id] = nil
        if selectedWorkroomID == workroom.id {
            selectedWorkroomID = nil
        }

        // Teardown continues in the background. We still collect its output so a failure
        // can be surfaced in an alert.
        Task {
            let log = ScriptLogSession(title: "Tearing down \(workroom.name)", phase: "teardown")
            do {
                try await WorkroomCLI.shared.delete(name: workroom.name, project: project.path) { text in
                    DispatchQueue.main.async { log.append(text) }
                }
            } catch {
                await reload()
                presentTeardownFailure(workroom, error: error, log: log)
            }
        }
    }

    /// Drops a workroom from the in-memory project list so the sidebar updates instantly.
    private func removeWorkroomLocally(_ workroom: Workroom, in project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let p = projects[idx]
        projects[idx] = Project(path: p.path, vcs: p.vcs, workrooms: p.workrooms.filter { $0.id != workroom.id })
    }

    /// Teardown failed (it ran in the background): pop an alert carrying the captured
    /// script output so the user can see why.
    private func presentTeardownFailure(_ workroom: Workroom, error: Error, log: ScriptLogSession) {
        let output = log.lines.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        errorTitle = "Teardown of ‘\(workroom.name)’ failed"
        errorMessage = output.isEmpty ? errorText(error) : output
    }

    private func errorText(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Menu-command convenience

    /// Open a new terminal tab in the selected workroom (⌘T).
    func newTerminalInSelectedWorkroom() {
        guard let workroom = selectedWorkroom, !workroom.hasBlockingWarning else { return }
        terminals.addTab(for: workroom)
    }

    /// Close the active terminal tab in the selected workroom (⌘W).
    func closeCurrentTerminalTab() {
        guard let workroom = selectedWorkroom,
              let active = terminals.activeTab(for: workroom) else { return }
        terminals.closeTab(active.id, for: workroom)
    }

    /// Focus the terminal tab at `index` (0-based, left-to-right) in the selected
    /// workroom (⌘1…⌘9). No-ops if there's no tab at that position.
    func focusTerminalTab(at index: Int) {
        guard let workroom = selectedWorkroom else { return }
        let tabs = terminals.tabs(for: workroom)
        guard tabs.indices.contains(index) else { return }
        terminals.select(tabs[index].id, for: workroom)
    }

    // MARK: Errors

    private func present(_ error: Error) {
        errorTitle = nil // generic title
        errorMessage = errorText(error)
    }
}

/// The live log for one create/delete run. Lines stream in from the CLI's NDJSON
/// stderr (see WorkroomCLI). A plain ObservableObject — all mutations happen on the
/// main thread (the store hops there before appending), so SwiftUI sees them safely.
final class ScriptLogSession: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let phase: String
    /// The workroom this log is docked under, once the CLI reports it exists. nil while
    /// the workroom is still being created.
    var workroomID: Workroom.ID?
    @Published private(set) var lines: [LogLine] = []
    @Published private(set) var isFinished = false
    @Published private(set) var failureMessage: String?

    init(title: String, phase: String) {
        self.title = title
        self.phase = phase
    }

    func append(_ text: String) {
        lines.append(LogLine(index: lines.count, text: Self.stripANSI(text)))
    }

    func finish(failure: String? = nil) {
        failureMessage = failure
        isFinished = true
    }

    struct LogLine: Identifiable {
        let index: Int
        let text: String
        var id: Int { index }
    }

    /// Strips ANSI SGR/escape sequences (e.g. color codes a setup script emits) so the
    /// log renders as clean text.
    private static let ansiRegex = try? NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*[A-Za-z]")
    static func stripANSI(_ s: String) -> String {
        guard let re = ansiRegex else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }
}
