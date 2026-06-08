import AppKit
import Defaults
import SwiftUI
import UserNotifications

@main
struct WorkroomApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = AppStore.shared
  @StateObject private var updater = Updater()

  init() {
    // Start Sentry first, before anything else can crash — the crash handler must be
    // installed as early as possible. Runs on the main thread (App.init does), as the SDK
    // requires. macOS-trimmed option set: see SentryConfig.start().
    SentryConfig.start()

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
        .environmentObject(store.terminals)
        .frame(minWidth: 900, minHeight: 560)
        .task { await store.bootstrap() }
    }
    .commands { WorkroomCommands(updater: updater) }

    Settings {
      SettingsView()
        .environmentObject(updater)
    }
  }
}

/// Installs a local key monitor for ⌘1…⌘9 to focus the workroom's Nth terminal tab.
/// Handled here (rather than as menu items) so the shortcuts work without cluttering the
/// menu, and the monitor sees the keys before the focused terminal does.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private var monitor: Any?
  /// The global ⌘§ show/hide shortcut while enabled, else nil (issue #13). Registered/torn down by
  /// `updateGlobalHotkey()` to follow the `globalHotkey` setting.
  private var showHideHotkey: GlobalHotkey?
  /// Observes the `globalHotkey` setting so toggling it takes effect immediately.
  private var hotkeyObservation: Task<Void, Never>?

  deinit { hotkeyObservation?.cancel() }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Disable native macOS window tabbing. It tabs whole app windows (each with its own
    // sidebar) — a level above our per-workroom terminal tabs and a poor fit for a
    // single-window, sidebar-driven app. Off, it also drops the auto-injected
    // "Show/Hide Tab Bar" + "Show All Tabs" View-menu items that otherwise read as if they
    // control the terminal tabs.
    NSWindow.allowsAutomaticWindowTabbing = false

    // Receive notification clicks (authorization is requested lazily on first post).
    UNUserNotificationCenter.current().delegate = self

    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
      // ⌘1–9: focus the Nth tab (caught here so it fires before the terminal swallows the digit).
      if flags == .command, let chars = event.charactersIgnoringModifiers,
        let digit = Int(chars), (1...9).contains(digit)
      {
        Task { @MainActor in AppStore.shared.focusTerminalTab(at: digit - 1) }
        return nil  // consume so it doesn't reach the terminal
      }
      // ⌥⌘arrows: move focus between split panes — consumed only when focus actually moves, so the
      // keys still reach the terminal when there's no split to navigate. (Virtual keycodes:
      // left 123 / right 124 / down 125 / up 126.)
      let arrows: [UInt16: PaneDirection] = [123: .left, 124: .right, 125: .down, 126: .up]
      if flags == [.command, .option], let direction = arrows[event.keyCode],
        MainActor.assumeIsolated({ AppStore.shared.focusPane(direction) })
      {
        return nil
      }
      return event
    }

    // ⌘-click-to-open-in-editor and copy-on-select now live inside GhosttySurfaceView (we own the
    // NSView), so the SwiftTerm-era NSEvent monitors that worked around its public-not-open methods
    // are gone.

    // Global ⌘§ to show/hide Workroom from anywhere (issue #13), gated by the `globalHotkey`
    // setting. Register now, then re-run on each change of *that* key (scoped, unlike the old
    // blanket didChangeNotification observer) so toggling the setting registers/unregisters it live.
    updateGlobalHotkey()
    hotkeyObservation = Task { @MainActor [weak self] in
      for await _ in Defaults.updates(.globalHotkey, initial: false) {
        self?.updateGlobalHotkey()
      }
    }
  }

  /// Register or tear down the global ⌘§ hotkey to match the `globalHotkey` setting.
  /// Idempotent — only (un)registers when the desired state differs from the current one — so it's
  /// safe to call on launch and on every change. Carbon's RegisterEventHotKey is system-wide and
  /// needs no permission; the key/modifier live in `GlobalHotkey.commandSection`.
  private func updateGlobalHotkey() {
    if Defaults[.globalHotkey] {
      if showHideHotkey == nil {
        showHideHotkey = GlobalHotkey.commandSection { AppDelegate.toggleAppVisibility() }
      }
    } else {
      showHideHotkey = nil  // GlobalHotkey.deinit unregisters
    }
  }

  /// Show/hide Workroom for the global hotkey: hide when we're frontmost, otherwise unhide and pull
  /// the app forward. Runs on the main thread (Carbon delivers hot-key events there).
  private static func toggleAppVisibility() {
    if NSApp.isActive {
      NSApp.hide(nil)
    } else {
      NSApp.unhide(nil)
      NSApp.activate(ignoringOtherApps: true)
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

  /// Confirm before quitting unless the user turned it off (`confirmOnQuit`, default on): quitting
  /// tears down every terminal (and anything running in them) at once, with no undo. The dialog's
  /// "Don't ask me again" checkbox turns the setting off (same key as the menu/Settings toggles).
  /// `@MainActor` so the `NSAlert` (a main-actor AppKit type) call is clean — AppKit always invokes
  /// this on the main thread. Closing a window doesn't quit the app, so this fires only on a quit.
  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // UI-test fixture runs quit cleanly (no modal) so XCUITest teardown never blocks on the dialog.
    guard Defaults[.confirmOnQuit], !UITestFixture.isActive else { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = "Quit Workroom?"
    alert.informativeText = "Quitting closes all terminals and stops any running processes."
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Don't ask me again"
    let shouldQuit = alert.runModal() == .alertFirstButtonReturn
    // Ticking the box stops future confirmations — whether they Quit or Cancel, the checkbox
    // means "stop asking". Writes the same key the menu/Settings toggles bind to.
    if alert.suppressionButton?.state == .on {
      Defaults[.confirmOnQuit] = false
    }
    return shouldQuit ? .terminateNow : .terminateCancel
  }

  /// Ordered libghostty teardown before exit: free every surface (which clears its callbacks first),
  /// then the runtime app + config. Fires only after `applicationShouldTerminate` approves the quit.
  @MainActor
  func applicationWillTerminate(_ notification: Notification) {
    AppStore.shared.terminals.reapAll()
    GhosttyApp.shared.shutdown()
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

/// Whether there are any pending notifications — published by RootView (which observes the
/// store), so "Go to Next Notification" can disable when the history is empty.
struct HasNotificationsKey: FocusedValueKey {
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
  var hasNotifications: Bool? {
    get { self[HasNotificationsKey.self] }
    set { self[HasNotificationsKey.self] = newValue }
  }
}

/// Menu-bar commands + keyboard shortcuts. They act on the shared store so they work
/// regardless of which pane has focus.
struct WorkroomCommands: Commands {
  @ObservedObject var updater: Updater
  @FocusedValue(\.workroomSelected) private var workroomSelected
  @FocusedValue(\.hasTerminal) private var hasTerminal
  @FocusedValue(\.hasNotifications) private var hasNotifications
  // Shared with RootView's inspector + toolbar toggle (same key) so all three stay in sync.
  @Default(.showNotifications) private var showNotifications
  // Same key as the Settings checkbox so the two stay in sync; GhosttySurfaceView reads it
  // on each selection, so toggling here takes effect on the next drag.
  @Default(.copyOnSelect) private var copyOnSelect
  // Gate the quit-confirmation alert. Same key as the Settings checkbox so the two stay in sync;
  // AppDelegate reads it in applicationShouldTerminate.
  @Default(.confirmOnQuit) private var confirmOnQuit

  var body: some Commands {
    CommandGroup(after: .appInfo) {
      // Sparkle update check (App menu, just below "About Workroom"). Disabled while a check
      // is already running. See Core/Updater.swift.
      Button("Check for Updates…") { updater.checkForUpdates() }
        .disabled(!updater.canCheckForUpdates)

      // App menu: symlink the bundled CLI into the user's PATH (like VS Code's "Install 'code'
      // command"). Prompts for admin only if the target dir needs it. See CommandLineInstaller.
      Button("Install ‘workroom’ Command in PATH…") {
        Task { await CommandLineInstaller.runFromMenu() }
      }
    }

    // Sit the quit-confirmation toggle just above Quit (default on): `.appVisibility` is the
    // Hide/Show All group, the last thing before Quit, so `after:` lands between it and Quit. A
    // divider separates it from that group; mirrored by the Settings checkbox.
    CommandGroup(after: .appVisibility) {
      Divider()
      Toggle("Confirm Before Quitting", isOn: $confirmOnQuit)
    }

    CommandGroup(after: .sidebar) {
      // View menu: toggle the notifications inspector (checkmark reflects open/closed).
      Toggle("Show Notifications", isOn: $showNotifications)
        .keyboardShortcut("n", modifiers: [.command, .option])

      // ⇧⌘N: jump to the oldest pending notification (bottom of the panel). Opening dismisses it,
      // so repeated presses walk the backlog oldest→newest. Disabled when there are none.
      Button("Go to Next Notification") {
        AppStore.shared.openOldestNotification()
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
      .disabled(hasNotifications != true)
    }

    CommandGroup(after: .pasteboard) {
      // Edit menu: toggle copy-on-select (checkmark reflects state). A divider sets it apart
      // from the standard Cut/Copy/Paste group above, since it governs clipboard behaviour
      // rather than performing an action. No shortcut — it's a set-and-forget preference,
      // mirrored by the Settings checkbox.
      Divider()
      Toggle("Copy on Select", isOn: $copyOnSelect)
    }

    // Drop the WindowGroup's auto-provided File ▸ New Window (⌘N). Workroom is single-window
    // (see NSWindow.allowsAutomaticWindowTabbing = false) — a second window just spawns a
    // redundant sidebar. Our own File-menu items below anchor at `after: .newItem`, so they
    // still render even though this group's default content is now empty.
    CommandGroup(replacing: .newItem) {}

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

      // Split the focused pane with a new terminal beside it (issue #3): ⌘D right, ⇧⌘D down.
      Button("Split Right") {
        AppStore.shared.splitFocusedRight()
      }
      .keyboardShortcut("d", modifiers: .command)
      .disabled(hasTerminal != true)

      Button("Split Down") {
        AppStore.shared.splitFocusedDown()
      }
      .keyboardShortcut("d", modifiers: [.command, .shift])
      .disabled(hasTerminal != true)

      Button("Add Project…") {
        AppStore.shared.requestAddProject = true
      }
      .keyboardShortcut("o", modifiers: .command)
    }
  }
}
