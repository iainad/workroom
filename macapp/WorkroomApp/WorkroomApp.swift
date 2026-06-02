import SwiftUI

@main
struct WorkroomApp: App {
    @StateObject private var store = AppStore.shared

    init() {
        // Ensure the in-process environment (inherited by the bundled `workroom`
        // binary and the terminals) can find git/jj, which a Finder-launched .app's
        // minimal PATH excludes.
        setenv("PATH", ShellEnvironment.path(), 1)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
                .task { await store.bootstrap() }
        }
        .commands { WorkroomCommands() }
    }
}

/// Menu-bar commands + keyboard shortcuts. They act on the shared store so they work
/// regardless of which pane has focus.
struct WorkroomCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Workroom") {
                Task { await AppStore.shared.createInSelectedProject() }
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Add Project…") {
                AppStore.shared.requestAddProject = true
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Reload") {
                Task { await AppStore.shared.reload() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Delete Workroom") {
                Task { await AppStore.shared.deleteSelectedWorkroom() }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(AppStore.shared.selectedWorkroom == nil)
        }
    }
}
