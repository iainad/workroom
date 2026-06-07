import AppKit
import Defaults
import SwiftUI

struct RootView: View {
  @EnvironmentObject var store: AppStore
  @EnvironmentObject var notifications: NotificationCenterStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Default(.theme) private var theme
  /// Bundle id of the last editor picked from the "Open in…" menu — the toolbar button's
  /// primary action reopens in it.
  @Default(.lastEditor) private var lastEditorID
  /// Whether the right-hand notifications inspector is open. `@Default` (not `@State`) so the
  /// View-menu command (WorkroomCommands) toggles the same value.
  @Default(.showNotifications) private var showNotifications

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
            UnreadBadge(count: notifications.total)
          }
        }
        .help("Notifications")
        .accessibilityLabel(
          notifications.total > 0
            ? "Notifications, \(notifications.total) unread" : "Notifications")
      }
    }
    .inspector(isPresented: $showNotifications) {
      NotificationsPanel(isOpen: showNotifications)
        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
    }
    .onAppear {
      applyAppearance()
      updateDockBadge(notifications.total)
    }
    .onChange(of: theme) { _ in applyAppearance() }
    // Mirror the aggregate notification count onto the Dock icon badge.
    .onChange(of: notifications.total) { updateDockBadge($0) }
    // Keep the root branch labels reasonably current: refresh when the app regains
    // focus (throttled, so rapid alt-tabbing doesn't fork a git/jj process per project).
    // Regaining focus also dismisses the now-visible terminal's notifications (you're looking at it).
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      store.dismissFocusedTerminalNotifications()
      Task { await store.reloadIfStale() }
    }
    // Publish selection state for menu-command enablement (see WorkroomCommands). While a
    // setup script blocks the selected workroom's terminal, report false so ⌘T can't open
    // a (hidden) terminal behind the setup pane; the toolbar's Open/Reveal still work.
    .focusedSceneValue(\.workroomSelected, terminalInteractionAvailable)
  }

  /// True when the selected target can host a terminal right now: it exists, isn't missing,
  /// and isn't currently blocked by a running setup script.
  private var terminalInteractionAvailable: Bool {
    guard let target = store.selectedTarget, !target.isMissing else { return false }
    if store.logs[target.id]?.blocking == true { return false }
    return true
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

  /// A target's terminal (root or workroom), with its setup log (if any). While a setup
  /// script runs (`log.blocking`), the log floats in a panel *over* the main pane and the
  /// terminal is withheld; otherwise a finished/legacy log docks beneath the terminal.
  /// Only workrooms ever have a log; for a root, `logs[target.id]` is always nil. The
  /// title/toolbar live on the outer container so they stay put across the transition.
  @ViewBuilder
  private func targetDetail(_ target: TerminalTarget) -> some View {
    let isBlocking = store.logs[target.id]?.blocking == true
    ZStack {
      // Base pane. While setup blocks the terminal, WorkroomTerminalsView is withheld so no
      // terminal is created — it mounts (and `.task` creates the first one) only once the
      // blocking log is cleared on Dismiss, revealing the terminal beneath the fading panel.
      if !isBlocking {
        VStack(spacing: 0) {
          WorkroomTerminalsView(target: target, sessions: store.terminals)

          if let log = store.logs[target.id] {
            Divider()
            ScriptLogPanel(session: log) { store.logs[target.id] = nil }
          }
        }
      }

      // Setup log, floating over the main pane (as if over the terminal).
      if let log = store.logs[target.id], log.blocking {
        SetupOverlay(session: log) {
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            store.logs[target.id] = nil
          }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .center)))
        .zIndex(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
              Button {
                lastEditorID = editor.id
                editor.open(target.path)
              } label: {
                Label {
                  Text(editor.name)
                } icon: {
                  Image(nsImage: editor.icon).renderingMode(.original)
                }
              }
            }
          } label: {
            Label {
              Text("Open in…")
            } icon: {
              // The toolbar auto-scales SF Symbols but renders a bitmap at its own size, so
              // fit the app icon into a hidden reference symbol to match the other toolbar icons.
              Image(systemName: "arrow.up.forward.app")
                .hidden()
                .overlay {
                  Image(nsImage: remembered.icon).renderingMode(.original).resizable().scaledToFit()
                }
            }
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

/// The header + scrolling body of a setup log. Shared between the full-pane blocking
/// setup view and the resizable under-terminal panel. A nil `onClose` hides the header
/// close button — the blocking view withholds it (you dismiss via its footer button,
/// and only once setup finishes).
struct ScriptLogContent: View {
  @ObservedObject var session: ScriptLogSession
  var onClose: (() -> Void)?
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
      if let onClose {
        Button(action: onClose) {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Close log")
        .accessibilityLabel("Close log")
      }
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

/// The setup log shown as a panel floating *over* the detail pane while a setup script
/// runs on a freshly created workroom (issue #18). It overlays the main pane — faint,
/// decorative terminal output behind it sells the "over the terminal" look — and blocks
/// it: no terminal is created underneath until the user dismisses. The panel springs in on
/// appear (the faded backdrop fades up, the card scales up). There's no close button while
/// setup runs; once it finishes (success or failure) a "Dismiss" button appears —
/// dismissing clears the log, which lets the real terminal mount and open beneath the
/// fading panel. `@ObservedObject` keeps streaming updates scoped here.
struct SetupOverlay: View {
  @ObservedObject var session: ScriptLogSession
  var onDismiss: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// Drives the enter animation. Flipped true in `onAppear` so the spring plays reliably
  /// regardless of how the containing detail pane was mounted (a `.transition` alone won't
  /// animate when the pane appears already-blocking from a fresh target selection).
  @State private var shown = false

  var body: some View {
    ZStack {
      // A fake CRT terminal behind the panel — purely cosmetic, so the floating card reads
      // as hovering over a terminal even though none is running yet (issue #18).
      FakeTerminalBackdrop()
        .opacity(shown ? 1 : 0)

      // A dim over the faux terminal so the green recedes and the card pops forward.
      Rectangle()
        .fill(Color.black.opacity(shown ? 0.25 : 0))
        .ignoresSafeArea()

      card
        .frame(maxWidth: 720, maxHeight: 520)
        .scaleEffect(shown ? 1 : 0.96)
        .opacity(shown ? 1 : 0)
        .padding(32)
    }
    .onAppear {
      guard !shown else { return }
      if reduceMotion {
        shown = true
      } else {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { shown = true }
      }
    }
  }

  private var card: some View {
    VStack(spacing: 0) {
      ScriptLogContent(session: session, onClose: nil)
      if session.isFinished {
        Divider()
        HStack {
          Spacer()
          Button("Dismiss", action: onDismiss)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("DismissSetup")
        }
        .padding(12)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: session.isFinished)
    .background(Color(nsColor: .windowBackgroundColor))
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
  }
}

/// A fake green-phosphor CRT terminal drawn behind `SetupOverlay`'s panel so it reads as
/// floating over a terminal. Purely decorative — no real terminal runs while setup is in
/// progress (issue #18). The content is an affectionate riff on the MU/TH/UR 6000 ("MOTHER")
/// interface from *Alien* (1979): dull phosphor green, scanlines, a slight defocus blur and a
/// faint flicker so it sits in the background. Static, non-interactive, hidden from a11y.
private struct FakeTerminalBackdrop: View {
  private enum Kind { case system, prompt, reply }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Dull phosphor green, à la a 1979 monochrome CRT well past its prime.
  private static let phosphor = Color(red: 0.34, green: 0.72, blue: 0.42)

  // MOTHER never had a prompt char; the "> " is our nod to a green terminal prompt.
  private static let script: [(Kind, String)] = [
    (.system, "WEYLAND-YUTANI CORP  —  MU/TH/UR 6000  ·  INTERFACE 2037 READY FOR INQUIRY"),
    (.reply, ""),
    (.reply, "USCSS NOSTROMO  ·  REG. 180924609  ·  COMMERCIAL TOWING VEHICLE, CLASS M"),
    (.reply, "CARGO: 20,000,000 TONS MINERAL ORE  ·  REFINERY UNDER TOW  ·  CREW 7"),
    (.reply, ""),
    (.prompt, "REQUEST WORKROOM STATUS REPORT"),
    (.reply, "WORKROOM ONLINE. ALL SYSTEMS NOMINAL. ENVIRONMENT PRESSURISED AND SEALED."),
    (.reply, "LIFE SUPPORT: GREEN   ·   DISK: GREEN   ·   NETWORK: GREEN   ·   VCS: JJ"),
    (.reply, ""),
    (.prompt, "WHAT IS THE NATURE OF THE SETUP SCRIPT"),
    (.reply, "ANALYZING SCRIPTS/WORKROOM_SETUP ..."),
    (.reply, "DEPENDENCIES RESOLVED. NODE_MODULES POPULATED. ENVIRONMENT STABLE."),
    (.reply, ""),
    (.prompt, "WHAT ARE MY CHANCES OF A CLEAN BUILD ON THE FIRST ATTEMPT"),
    (.reply, "DOES NOT COMPUTE."),
    (.reply, ""),
    (.system, "SPECIAL ORDER 937  —  SCIENCE OFFICER EYES ONLY  —  PRIORITY ONE"),
    (.reply, "BOOTSTRAP ENVIRONMENT AND RUN ALL PENDING MIGRATIONS TO COMPLETION."),
    (.reply, "SEED DATABASE. WARM CACHES. INSTALL GIT HOOKS. COMPILE ASSETS."),
    (.reply, "RETURN A WORKING WORKROOM FOR ANALYSIS. ALL OTHER CONSIDERATIONS SECONDARY."),
    (.reply, "CREW EXPENDABLE.   BRANCH EXPENDABLE.   STASH EXPENDABLE."),
    (.reply, ""),
    (.prompt, "git push --force origin main"),
    (.reply, "UNABLE TO COMPUTE. THE OPTION TO OVERRIDE EXPIRES IN T-MINUS 00:05:00."),
    (.reply, ""),
    (.prompt, "OVERRIDE  —  AUTHORIZATION RIPLEY 7-0-4-1-7-C"),
    (.reply, "DETONATION SEQUENCE ABORTED. HAVE A PLEASANT BUILD."),
    (.reply, ""),
    (.prompt, ""),
  ]

  var body: some View {
    Group {
      if reduceMotion {
        crt
      } else {
        // A faint flicker — the tube never sits perfectly still.
        TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { context in
          crt.opacity(Self.flickerOpacity(context.date))
        }
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var crt: some View {
    ZStack {
      // Near-black with a faint green cast, like warmed-up phosphor.
      Color(red: 0.01, green: 0.035, blue: 0.02)

      VStack(alignment: .leading, spacing: 3) {
        ForEach(Array(Self.script.enumerated()), id: \.offset) { _, entry in
          line(entry.0, entry.1)
        }
        Spacer(minLength: 0)
      }
      .font(.system(.callout, design: .monospaced))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(20)
      .shadow(color: Self.phosphor.opacity(0.35), radius: 1.5)  // soft phosphor glow
      .blur(radius: 0.6)  // a touch out of focus
    }
    .overlay(Scanlines())
    // Vignette: darken the edges/corners so it reads as a curved tube in the background.
    .overlay(
      EllipticalGradient(colors: [.clear, .black.opacity(0.45)], center: .center)
        .allowsHitTesting(false)
    )
  }

  @ViewBuilder
  private func line(_ kind: Kind, _ text: String) -> some View {
    switch kind {
    case .system:
      Text(text.isEmpty ? " " : text)
        .foregroundStyle(Self.phosphor)
        .fontWeight(.semibold)
    case .prompt:
      // A trailing empty prompt becomes the blinking-cursor line.
      Text(text.isEmpty ? "> █" : "> \(text)")
        .foregroundStyle(Self.phosphor)
    case .reply:
      Text(text.isEmpty ? " " : text)
        .foregroundStyle(Self.phosphor.opacity(0.5))
    }
  }

  /// Smooth pseudo-random flicker in ~[0.92, 1.0] — summed sines so it never repeats obviously.
  private static func flickerOpacity(_ date: Date) -> Double {
    let t = date.timeIntervalSinceReferenceDate
    let noise = (sin(t * 13.0) + sin(t * 27.3) + sin(t * 41.7)) / 3.0  // [-1, 1]
    return 0.92 + 0.08 * (noise * 0.5 + 0.5)
  }
}

/// Horizontal CRT scanlines: thin dark lines every few points, drawn over the terminal.
private struct Scanlines: View {
  var body: some View {
    Canvas { context, size in
      var y = 0.0
      while y < size.height {
        context.fill(
          Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
          with: .color(.black.opacity(0.2)))
        y += 3
      }
    }
    .allowsHitTesting(false)
  }
}
