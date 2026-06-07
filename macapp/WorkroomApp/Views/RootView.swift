import AppKit
import SwiftUI

struct RootView: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @AppStorage(ThemePreference.storageKey) private var theme: ThemePreference = .system
  /// Bundle id of the last editor picked from the "Open in…" menu — the toolbar button's
  /// primary action reopens in it.
  @AppStorage("openInEditorBundleID") private var lastEditorID = ""
  /// Whether the right-hand notifications inspector is open. `@AppStorage` (not `@State`) so the
  /// View-menu command (WorkroomCommands) toggles the same value.
  @AppStorage(NotificationsInspector.storageKey) private var showNotifications = false

  var body: some View {
    NavigationSplitView {
      ProjectSidebar()
        .frame(minWidth: 240)
        // Persist the user-dragged sidebar width across launches (issue #14) via the
        // underlying NSSplitView's autosave — SwiftUI offers no width binding.
        .background(SplitViewAutosave(name: "WorkroomSidebarSplit"))
    } detail: {
      detail
    }
    .alert(
      store.errorTitle ?? "Something went wrong",
      isPresented: Binding(
        get: { store.errorMessage != nil },
        set: {
          if !$0 {
            store.errorMessage = nil
            store.errorTitle = nil
          }
        }
      )
    ) {
      Button("OK", role: .cancel) {
        store.errorMessage = nil
        store.errorTitle = nil
      }
    } message: {
      Text(store.errorMessage ?? "")
    }
    // The notifications inspector + its toolbar toggle live at the split-view level so they're
    // available even when nothing is selected (a backgrounded terminal can fire any time).
    .toolbar {
      ToolbarItem {
        Button {
          showNotifications.toggle()
        } label: {
          HStack(spacing: 3) {
            Image(systemName: "bell")
            UnreadBadge(count: notifications.totalUnread)
          }
        }
        .help("Notifications")
        .accessibilityLabel(
          notifications.totalUnread > 0
            ? "Notifications, \(notifications.totalUnread) unread" : "Notifications")
      }
    }
    .inspector(isPresented: $showNotifications) {
      NotificationsPanel(isOpen: showNotifications)
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
    .onAppear {
      applyAppearance()
      updateDockBadge(notifications.totalUnread)
    }
    .onChange(of: theme) { _ in applyAppearance() }
    // Mirror the aggregate unread count onto the Dock icon badge.
    .onChange(of: notifications.totalUnread) { updateDockBadge($0) }
    // Keep the root branch labels reasonably current: refresh when the app regains
    // focus (throttled, so rapid alt-tabbing doesn't fork a git/jj process per project).
    // Regaining focus also clears the now-visible terminal's unread (you're looking at it).
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      store.markFocusedTerminalRead()
      Task { await store.reloadIfStale() }
    }
    // Publish selection state for menu-command enablement (see WorkroomCommands).
    .focusedSceneValue(\.workroomSelected, store.selectedTarget.map { !$0.isMissing } ?? false)
  }

  /// Pushes the chosen appearance onto the running app. nil (System) tells AppKit to
  /// follow the OS appearance and keep tracking it. Terminals follow the appearance too, but
  /// only those currently in a window get AppKit's change hook — so sweep them all explicitly
  /// (see `TerminalSessions.applyThemeToAll`).
  private func applyAppearance() {
    NSApp.appearance = theme.nsAppearance
    store.terminals.applyThemeToAll()
  }

  /// Show the unread count on the Dock icon, clearing the badge at zero (HIG 7.4).
  private func updateDockBadge(_ count: Int) {
    NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
  }

  @ViewBuilder
  private var detail: some View {
    if let target = store.selectedTarget {
      if target.isMissing {
        ContentUnavailableView(
          "Directory not found",
          systemImage: "questionmark.folder",
          description: Text(
            "\(target.title) points at a path that no longer exists.\n\(target.path)")
        )
      } else {
        targetDetail(target)
      }
    } else {
      ContentUnavailableView(
        "Nothing selected",
        systemImage: "terminal",
        description: Text(
          "Select a project's root or a workroom to open a terminal in its directory, or create one."
        )
      )
      // Nothing selected → nothing to title, so drop the toolbar bar/separator and the
      // window title for a clean empty state.
      .navigationTitle("")
      .toolbarBackground(.hidden, for: .windowToolbar)
    }
  }

  /// A target's terminal (root or workroom), with its setup log (if any) docked beneath.
  /// Only workrooms ever have a docked log; for a root, `logs[target.id]` is always nil.
  @ViewBuilder
  private func targetDetail(_ target: TerminalTarget) -> some View {
    VStack(spacing: 0) {
      WorkroomTerminalsView(target: target, sessions: store.terminals)

      if let log = store.logs[target.id] {
        Divider()
        ScriptLogPanel(session: log) { store.logs[target.id] = nil }
      }
    }
    .navigationTitle(target.title)
    .navigationSubtitle(target.path)
    .toolbar {
      ToolbarItemGroup {
        let editors = ExternalEditor.installed
        if !editors.isEmpty {
          // Primary action reopens in the remembered editor; the menu switches it.
          let remembered = editors.first { $0.id == lastEditorID } ?? editors[0]
          Menu {
            ForEach(editors) { editor in
              Button(editor.name) {
                lastEditorID = editor.id
                editor.open(target.path)
              }
            }
          } label: {
            Label("Open in…", systemImage: "arrow.up.forward.app")
          } primaryAction: {
            remembered.open(target.path)
          }
          .help("Open in \(remembered.name)")
        }

        Button {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target.path)])
        } label: {
          Label("Reveal in Finder", systemImage: "folder")
        }
        .help("Reveal in Finder")

        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(target.path, forType: .string)
        } label: {
          Label("Copy Path", systemImage: "doc.on.doc")
        }
        .help("Copy path")
      }
    }
  }
}

/// The header + scrolling body of a setup log. Shared between the full-pane create
/// view and the resizable under-terminal panel.
struct ScriptLogContent: View {
  @ObservedObject var session: ScriptLogSession
  var onClose: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      logBody
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      statusIcon
      Text(session.title).fontWeight(.medium).lineLimit(1)
      if let message = session.failureMessage {
        Text("— \(message)")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer()
      Button(action: onClose) {
        Image(systemName: "xmark.circle.fill")
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Close log")
      .accessibilityLabel("Close log")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var statusIcon: some View {
    if !session.isFinished {
      ProgressView().controlSize(.small)
    } else if session.failureMessage != nil {
      Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
    } else {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    }
  }

  private var logBody: some View {
    ScrollViewReader { proxy in
      ScrollView {
        if session.lines.isEmpty {
          Text(session.isFinished ? "No output." : "Waiting for output…")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        } else {
          LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(session.lines) { line in
              Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(line.id)
            }
          }
          .padding(12)
        }
      }
      .onChange(of: session.lines.count) { _ in
        if let last = session.lines.last {
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
    }
    .frame(maxHeight: .infinity)
    .background(Color(nsColor: .textBackgroundColor))
  }
}

/// A setup log docked under a workroom's terminal: the shared content plus a draggable
/// top edge to resize it. It stays up after the run completes (the user closes it) so
/// the output remains available for review.
struct ScriptLogPanel: View {
  @ObservedObject var session: ScriptLogSession
  var onClose: () -> Void

  @State private var height: CGFloat = 200
  @State private var dragStartHeight: CGFloat?

  private static let minHeight: CGFloat = 100
  private static let maxHeight: CGFloat = 600

  var body: some View {
    VStack(spacing: 0) {
      resizeHandle
      ScriptLogContent(session: session, onClose: onClose)
    }
    .frame(height: height)
  }

  /// A thin grabber along the top edge to resize the panel.
  private var resizeHandle: some View {
    Rectangle()
      .fill(Color.secondary.opacity(0.0001))  // invisible but hit-testable
      .frame(height: 5)
      .contentShape(Rectangle())
      .gesture(
        DragGesture()
          .onChanged { value in
            let start = dragStartHeight ?? height
            if dragStartHeight == nil { dragStartHeight = start }
            height = min(Self.maxHeight, max(Self.minHeight, start - value.translation.height))
          }
          .onEnded { _ in dragStartHeight = nil }
      )
      .onHover { inside in
        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
      }
  }
}
