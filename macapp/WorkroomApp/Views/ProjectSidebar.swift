import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebar: View {
    @EnvironmentObject var store: AppStore
    @State private var showImporter = false
    @AppStorage(ThemePreference.storageKey) private var theme: ThemePreference = .system

    var body: some View {
        Group {
            if store.projects.isEmpty {
                EmptyStateView(
                    systemImage: "folder.badge.plus",
                    title: "No projects yet",
                    message: "Add a Git or Jujutsu project folder to start managing its workrooms.",
                    action: (label: "Add Project…", run: { showImporter = true })
                )
            } else {
                List(store.projects, selection: $store.selectedProjectID) { project in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.displayName).fontWeight(.medium)
                            Text(displayPath(project.path))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(project.vcs.uppercased())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(project.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { themeToggle }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem {
                Button {
                    showImporter = true
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .keyboardShortcut("o", modifiers: .command)
                .help("Add a project folder")
            }
        }
        .onChange(of: store.requestAddProject) { request in
            if request {
                showImporter = true
                store.requestAddProject = false
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                Task { await store.addProject(url) }
            }
        }
    }

    /// Bottom-left appearance toggle. One click cycles System → Light → Dark; the icon
    /// and tooltip reflect the active mode.
    private var themeToggle: some View {
        HStack {
            Button {
                theme = theme.next
            } label: {
                Image(systemName: theme.symbol)
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Theme: \(theme.label) — click to switch to \(theme.next.label)")
            .accessibilityLabel("Theme: \(theme.label)")

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
