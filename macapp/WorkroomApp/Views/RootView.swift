import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        NavigationSplitView {
            ProjectSidebar()
                .frame(minWidth: 220)
        } content: {
            if let project = store.selectedProject {
                WorkroomListView(project: project)
                    .frame(minWidth: 240)
            } else {
                EmptyStateView(
                    systemImage: "sidebar.left",
                    title: "Select a project",
                    message: "Choose a project on the left, or add one."
                )
                .frame(minWidth: 240)
            }
        } detail: {
            detail
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let workroom = store.selectedWorkroom {
            if workroom.hasBlockingWarning {
                EmptyStateView(
                    systemImage: "questionmark.folder",
                    title: "Directory not found",
                    message: "\(workroom.name) points at a path that no longer exists.\n\(workroom.path)"
                )
            } else {
                TerminalContainerView(workroom: workroom, sessions: store.terminals)
                    .id(workroom.id) // mount the right cached terminal; others stay alive
                    .navigationTitle(workroom.name)
                    .navigationSubtitle(workroom.path)
                    .toolbar {
                        ToolbarItemGroup {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workroom.path)])
                            } label: {
                                Label("Reveal in Finder", systemImage: "folder")
                            }
                            .help("Reveal in Finder")

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(workroom.path, forType: .string)
                            } label: {
                                Label("Copy Path", systemImage: "doc.on.doc")
                            }
                            .help("Copy workroom path")
                        }
                    }
            }
        } else {
            EmptyStateView(
                systemImage: "terminal",
                title: "No workroom selected",
                message: "Select a workroom to open a terminal in its directory, or create one."
            )
        }
    }
}
