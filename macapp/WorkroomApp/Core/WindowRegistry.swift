import AppKit
import Defaults
import SwiftUI

/// The single app-level coordinator for the multi-window world (issue #70). Each window owns its own
/// `AppStore` (per-window selection, terminals, splits, run state); this registry is the *only*
/// shared coordination point above them, for the things that are genuinely app-scoped:
///
/// - **Key/active routing** — the `AppDelegate` key-event monitor and a terminal surface's
///   context-menu actions act on whichever window is key (`keyStore`).
/// - **Last-active capture** — `lastActiveStore` tracks the most recent *workroom* window to become
///   key, captured before any modal (quit alert / Settings) can steal key status, so quit-time
///   persistence reads the right window.
/// - **Aggregation** — the Dock badge (and menu-bar item) sum across every window's notifications.
/// - **Run-command ownership** — a workroom's run command is single-owner across windows; a second
///   window's Run focuses the owner instead of forking a duplicate server (issue #70 / issue #7).
/// - **Quit/close de-dup** — `isTerminating` suppresses the per-window close prompt during a quit.
///
/// Per-window logic stays in `AppStore`; this holds only weak references, so closed windows fall out
/// on the next prune.
@MainActor
final class WindowRegistry: ObservableObject {
  static let shared = WindowRegistry()

  private final class Entry {
    weak var window: NSWindow?
    weak var store: AppStore?
    init(window: NSWindow, store: AppStore) {
      self.window = window
      self.store = store
    }
  }
  private var entries: [Entry] = []

  /// True while the app is terminating, so a window's close handler doesn't prompt/stop run commands
  /// a second time on top of `applicationShouldTerminate` (issue #70, OV #10).
  var isTerminating = false

  /// The most recent registered (workroom) window to become key. Updated only for registered windows,
  /// so a modal alert / Settings becoming key never overwrites it — quit persistence can trust it.
  private(set) weak var lastActiveStore: AppStore?

  /// Combined unread notification count across every window — drives the menu-bar label + Dock badge
  /// (issue #70). `@Published` so the `MenuBarExtra` label re-renders as any window's count changes.
  @Published private(set) var aggregateUnread = 0

  init() {
    // Track the active workroom window. Only registered windows update `lastActiveStore`, so the quit
    // alert / Settings / menu-bar popover becoming key leaves the last *workroom* selection intact.
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { [weak self] note in
      MainActor.assumeIsolated {
        guard let self, let window = note.object as? NSWindow,
          let store = self.store(for: window)
        else { return }
        self.lastActiveStore = store
      }
    }
  }

  // MARK: Registration

  /// Register (or re-register) a window with its store. Idempotent — `WindowAccessor` may resolve the
  /// same window more than once. Prunes any dead entries while here.
  func register(window: NSWindow, store: AppStore) {
    prune()
    if let existing = entries.first(where: { $0.window === window }) {
      existing.store = store
    } else {
      entries.append(Entry(window: window, store: store))
    }
    if lastActiveStore == nil { lastActiveStore = store }
    recomputeBadge()
  }

  func unregister(window: NSWindow) {
    entries.removeAll { $0.window === window || $0.window == nil }
    recomputeBadge()
  }

  private func prune() {
    entries.removeAll { $0.window == nil || $0.store == nil }
  }

  // MARK: Lookup

  /// Every live window's store.
  var allStores: [AppStore] {
    prune()
    return entries.compactMap(\.store)
  }

  func store(for window: NSWindow?) -> AppStore? {
    guard let window else { return nil }
    return entries.first { $0.window === window }?.store
  }

  /// The store of the window that should receive a global key event / surface action: the key window
  /// if it's one of ours, else the last active workroom window, else any.
  var keyStore: AppStore? {
    store(for: NSApp.keyWindow) ?? lastActiveStore ?? allStores.first
  }

  /// The window store that owns the terminal tab `tabID` (each tab id is unique across windows), for
  /// routing an OS-notification click to the right window (issue #70, OV #4).
  func ownerOf(tabID: TerminalTab.ID) -> AppStore? {
    allStores.first { $0.terminals.containsTab(tabID) }
  }

  // MARK: Aggregation

  /// Mirror the *combined* unread count across all windows onto the menu-bar label + Dock badge
  /// (issue #70). Replaces the per-store `DockBadge.apply` so a second window can't clobber the
  /// first's count. Called from each store's `notifications.onTotalChange` and on register/unregister.
  func recomputeBadge() {
    aggregateUnread = allStores.reduce(0) { $0 + $1.notifications.total }
    DockBadge.apply(aggregateUnread)
  }

  // MARK: Run-command ownership

  /// The other window already running `target`'s run command, if any. Derived from each window's live
  /// `runStates` (no separate map to drift): a second window's Run focuses this owner instead of
  /// forking a duplicate dev server on the same port (issue #70 / issue #7).
  func runOwner(for target: TerminalTarget.ID, excluding: AppStore) -> AppStore? {
    allStores.first { $0 !== excluding && ($0.runStates[target]?.isRunning ?? false) }
  }

  // MARK: Quit

  /// Any window with a live run command — gates the graceful-stop-on-quit (issue #7 / #70).
  var hasAnyLiveRunCommand: Bool { allStores.contains(where: \.hasLiveRunCommand) }

  /// Ctrl-C every window's live run commands and let them exit before the process dies, so dev
  /// servers release their ports/pidfiles instead of being orphaned by the OS hangup (issue #7).
  /// Calls `completion` once all windows have stopped (or each one's timeout elapses).
  func gracefullyStopAllWindows(timeout: TimeInterval, completion: @escaping () -> Void) {
    let live = allStores.filter(\.hasLiveRunCommand)
    guard !live.isEmpty else {
      completion()
      return
    }
    let group = DispatchGroup()
    for store in live {
      group.enter()
      store.gracefullyStopAllRunCommands(timeout: timeout) { group.leave() }
    }
    group.notify(queue: .main) { completion() }
  }
}

/// A forwarding `NSWindowDelegate` proxy that intercepts only `windowShouldClose:` so a window with a
/// live run command confirms and gracefully stops it before closing (issue #70, A3) — otherwise the
/// dev server is orphaned against a torn-down window (the per-window form of issue #7). Every other
/// delegate message forwards to SwiftUI's original delegate, so scene/restoration behaviour is intact.
final class WindowCloseGuard: NSObject, NSWindowDelegate {
  private weak var store: AppStore?
  private weak var forwarding: NSWindowDelegate?

  init(store: AppStore, forwarding: NSWindowDelegate?) {
    self.store = store
    self.forwarding = forwarding
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    MainActor.assumeIsolated {
      // During an app quit, `applicationShouldTerminate` already prompts + stops every window, so
      // don't prompt again here (de-dup, OV #10). No live run command → nothing to stop, close now.
      guard let store, !WindowRegistry.shared.isTerminating, store.hasLiveRunCommand else {
        return true
      }
      if Defaults[.confirmOnQuit] {
        let alert = NSAlert()
        alert.messageText = "Close this window?"
        alert.informativeText = "It has a running process. Closing the window will stop it."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
      }
      // Stop the run command(s), then close — return false now so the surfaces stay alive for the
      // graceful Ctrl-C + wait and are never freed mid-IO (the no-mass-free rule).
      store.gracefullyStopAllRunCommands(timeout: 5) { sender.close() }
      return false
    }
  }

  override func responds(to aSelector: Selector!) -> Bool {
    super.responds(to: aSelector) || (forwarding?.responds(to: aSelector) ?? false)
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? { forwarding }
}

/// Bridges a SwiftUI view to its hosting `NSWindow`. Drop it in a `.background(...)`; once the view
/// is in the window tree it resolves `view.window` and hands it back so the owning `AppStore` can
/// register with `WindowRegistry`.
struct WindowAccessor: NSViewRepresentable {
  let onResolve: (NSWindow) -> Void

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async { [weak view] in
      if let window = view?.window { onResolve(window) }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    DispatchQueue.main.async { [weak nsView] in
      if let window = nsView?.window { onResolve(window) }
    }
  }
}
