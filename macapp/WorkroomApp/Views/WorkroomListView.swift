import SwiftUI

struct WorkroomListView: View {
    @EnvironmentObject var store: AppStore
    let project: Project

    @State private var pendingDelete: Workroom?

    private var isBusy: Bool { store.busyProjects.contains(project.path) }

    var body: some View {
        Group {
            if project.workrooms.isEmpty {
                EmptyStateView(
                    systemImage: "square.stack.3d.up",
                    title: "No workrooms yet",
                    message: "Create your first workroom in \(project.displayName).",
                    action: (label: "Create Workroom", run: { Task { await store.createWorkroom(in: project) } })
                )
            } else {
                List(project.workrooms, selection: $store.selectedWorkroomID) { workroom in
                    row(workroom)
                        .tag(workroom.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                pendingDelete = workroom
                            } label: {
                                Label("Delete \(workroom.name)", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle(project.displayName)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.createWorkroom(in: project) }
                } label: {
                    Label("New Workroom", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(isBusy)
                .help("Create a new workroom")
            }
        }
        .confirmationDialog(
            pendingDelete.map { "Delete '\($0.name)'?" } ?? "Delete workroom?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let workroom = pendingDelete {
                    Task { await store.deleteWorkroom(workroom, in: project) }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("This removes the workroom's directory and runs its teardown script. For Git, the branch is left in place.")
        }
    }

    @ViewBuilder
    private func row(_ workroom: Workroom) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(workroom.name).fontWeight(.medium)
                Text(workroom.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            }
            ForEach(workroom.warnings, id: \.kind) { warning in
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(warning.message)
            }
        }
    }
}
