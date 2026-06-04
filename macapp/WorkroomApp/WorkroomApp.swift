import AppKit
import SwiftUI

@main
struct WorkroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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

/// Installs a local key monitor for ⌘1…⌘9 to focus the workroom's Nth terminal tab.
/// Handled here (rather than as menu items) so the shortcuts work without cluttering the
/// menu, and the monitor sees the keys before the focused terminal does.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: Any?
    private var mouseUpMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard flags == .command,
                  let chars = event.charactersIgnoringModifiers,
                  let digit = Int(chars), (1...9).contains(digit)
            else { return event }
            Task { @MainActor in AppStore.shared.focusTerminalTab(at: digit - 1) }
            return nil // consume so it doesn't reach the terminal
        }

        // Copy-on-select: after each left-mouse-up, copy the focused terminal's selection
        // (if any) to the pasteboard. A monitor — not a `mouseUp` override — because
        // SwiftTerm's `mouseUp` is `public`, not `open`. See `CopyOnSelect`.
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            Task { @MainActor in CopyOnSelect.copyActiveSelection() }
            return event // don't consume — the terminal still needs the event
        }
    }
}

/// Whether the focused window has a usable terminal target selected (a root or a workroom,
/// and not a missing directory). Published via `focusedSceneValue` (see RootView) so menu
/// commands can enable/disable against it — a Commands body doesn't re-evaluate when the
/// shared store changes directly, but it does track focused values.
struct WorkroomSelectedKey: FocusedValueKey {
    typealias Value = Bool
}

/// Whether the selected workroom has at least one open terminal — published by
/// WorkroomTerminalsView (which observes the sessions), so "Close Terminal" can disable
/// when there's nothing to close.
struct HasTerminalKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var workroomSelected: Bool? {
        get { self[WorkroomSelectedKey.self] }
        set { self[WorkroomSelectedKey.self] = newValue }
    }
    var hasTerminal: Bool? {
        get { self[HasTerminalKey.self] }
        set { self[HasTerminalKey.self] = newValue }
    }
}

/// Menu-bar commands + keyboard shortcuts. They act on the shared store so they work
/// regardless of which pane has focus.
struct WorkroomCommands: Commands {
    @FocusedValue(\.workroomSelected) private var workroomSelected
    @FocusedValue(\.hasTerminal) private var hasTerminal
    @AppStorage(CopyOnSelect.storageKey) private var copyOnSelect = true

    var body: some Commands {
        // Sits in the Edit menu next to Cut/Copy/Paste; renders as a checkmarked item.
        CommandGroup(after: .pasteboard) {
            Toggle("Copy on Select", isOn: $copyOnSelect)
        }

        CommandGroup(after: .newItem) {
            Button("New Terminal") {
                AppStore.shared.newTerminalInSelectedTarget()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(workroomSelected != true)

            // ⌘W: "Close Terminal" sits above the standard File ▸ Close, so it wins the ⌘W
            // equivalent while enabled (Close keeps no shortcut).
            Button("Close Terminal") {
                AppStore.shared.closeCurrentTerminalTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(hasTerminal != true)

            Button("Add Project…") {
                AppStore.shared.requestAddProject = true
            }
            .keyboardShortcut("o", modifiers: .command)
        }
    }
}
