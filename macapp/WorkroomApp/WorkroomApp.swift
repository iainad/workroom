import AppKit
import SwiftUI
import UserNotifications

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
        .environmentObject(store.notifications)
        .frame(minWidth: 900, minHeight: 560)
        .task { await store.bootstrap() }
    }
    .commands { WorkroomCommands() }

    Settings {
      SettingsView()
    }
  }
}

/// Installs a local key monitor for ⌘1…⌘9 to focus the workroom's Nth terminal tab.
/// Handled here (rather than as menu items) so the shortcuts work without cluttering the
/// menu, and the monitor sees the keys before the focused terminal does.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private var monitor: Any?
  private var mouseUpMonitor: Any?
  private var mouseMovedMonitor: Any?
  private var flagsChangedMonitor: Any?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Receive notification clicks (authorization is requested lazily on first post).
    UNUserNotificationCenter.current().delegate = self

    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
      guard flags == .command,
        let chars = event.charactersIgnoringModifiers,
        let digit = Int(chars), (1...9).contains(digit)
      else { return event }
      Task { @MainActor in AppStore.shared.focusTerminalTab(at: digit - 1) }
      return nil  // consume so it doesn't reach the terminal
    }

    // On left-mouse-up: first, a ⌘-click on a file path opens it in the chosen editor (consuming
    // the event so SwiftTerm doesn't also hand it to NSWorkspace — see `TerminalLinkOpener`).
    // Otherwise, copy-on-select copies the focused terminal's selection (if any) to the
    // pasteboard. Monitors — not a `mouseUp` override — because SwiftTerm's `mouseUp` is
    // `public`, not `open`. See `CopyOnSelect`.
    mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
      if TerminalLinkOpener.handleCommandClick(event) {
        return nil  // opened in the editor; consume so SwiftTerm doesn't double-handle it
      }
      Task { @MainActor in CopyOnSelect.copyActiveSelection() }
      return event  // don't consume — the terminal still needs the event
    }

    // Pointing-hand cursor over ⌘-clickable links/paths. The `.mouseMoved` monitor tracks
    // movement while ⌘ is held (SwiftTerm only emits moved events then); the `.flagsChanged`
    // monitor catches ⌘ press/release while the pointer is stationary. Monitors — not a
    // `cursorUpdate` override — because SwiftTerm's cursor methods are `public`, not `open`.
    // See `LinkCursor`. Both deliberately don't consume the event.
    mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
      Task { @MainActor in LinkCursor.update() }
      return event
    }
    flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
      Task { @MainActor in LinkCursor.update() }
      return event
    }
  }

  /// A notification was clicked: route to its terminal (the ids ride in `userInfo`). Reuses the
  /// same `openTerminal` path as an in-app panel tap, so there's one routing implementation.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    if let targetID = info["targetID"] as? String {
      let tabID = (info["tabID"] as? String).flatMap(UUID.init(uuidString:))
      let notifID = (info["notifID"] as? String).flatMap(UUID.init(uuidString:))
      Task { @MainActor in
        AppStore.shared.openTerminal(targetID: targetID, tabID: tabID, notifID: notifID)
      }
    }
    completionHandler()
  }

  /// Always confirm before quitting: quitting tears down every terminal (and anything
  /// running in them) at once, with no undo. `@MainActor` so the `NSAlert` (a main-actor
  /// AppKit type) call is clean — AppKit always invokes this on the main thread. Closing a
  /// window doesn't quit the app, so this gate fires only on a real quit.
  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let alert = NSAlert()
    alert.messageText = "Quit Workroom?"
    alert.informativeText = "Quitting closes all terminals and stops any running processes."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
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
  // Shared with RootView's inspector + toolbar toggle (same key) so all three stay in sync.
  @AppStorage(NotificationsInspector.storageKey) private var showNotifications = false

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      // View menu: toggle the notifications inspector (checkmark reflects open/closed).
      Toggle("Show Notifications", isOn: $showNotifications)
        .keyboardShortcut("n", modifiers: [.command, .option])
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
