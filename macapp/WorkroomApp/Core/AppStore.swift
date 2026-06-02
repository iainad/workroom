import Foundation
import SwiftUI

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
    @Published var isLoading = false
    /// Project paths with an in-flight create/delete (for per-row progress + disabling).
    @Published var busyProjects: Set<String> = []
    /// Set by the "Add Project" menu command to trigger the sidebar's file importer.
    @Published var requestAddProject = false

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
        do {
            let created = try await WorkroomCLI.shared.create(project: project.path)
            await reload()
            selectedProjectID = project.id
            selectedWorkroomID = created.name
        } catch {
            // Even on (partial) failure, reload so a "created but setup failed" workroom shows up.
            await reload()
            present(error)
        }
    }

    func deleteWorkroom(_ workroom: Workroom, in project: Project) async {
        busyProjects.insert(project.path)
        defer { busyProjects.remove(project.path) }
        // Tear down its terminal before removing the workspace.
        terminals.reap(workroom.id)
        if selectedWorkroomID == workroom.id {
            selectedWorkroomID = nil
        }
        do {
            try await WorkroomCLI.shared.delete(name: workroom.name, project: project.path)
            await reload()
        } catch {
            present(error)
        }
    }

    // MARK: Menu-command convenience

    func createInSelectedProject() async {
        guard let project = selectedProject else { return }
        await createWorkroom(in: project)
    }

    func deleteSelectedWorkroom() async {
        guard let project = selectedProject, let workroom = selectedWorkroom else { return }
        await deleteWorkroom(workroom, in: project)
    }

    // MARK: Errors

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
