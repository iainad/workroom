import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @AppStorage(ThemePreference.storageKey) private var theme: ThemePreference = .system

    var body: some View {
        NavigationSplitView {
            ProjectSidebar()
                .frame(minWidth: 240)
        } detail: {
            detail
        }
        .alert(
            store.errorTitle ?? "Something went wrong",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil; store.errorTitle = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil; store.errorTitle = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onAppear { applyAppearance() }
        .onChange(of: theme) { _ in applyAppearance() }
    }

    /// Pushes the chosen appearance onto the running app. nil (System) tells AppKit to
    /// follow the OS appearance and keep tracking it.
    private func applyAppearance() {
        NSApp.appearance = theme.nsAppearance
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
                workroomDetail(workroom)
            }
        } else {
            EmptyStateView(
                systemImage: "terminal",
                title: "No workroom selected",
                message: "Select a workroom to open a terminal in its directory, or create one."
            )
            // No workroom → nothing to title, so drop the toolbar bar/separator and the
            // window title for a clean empty state.
            .navigationTitle("")
            .toolbarBackground(.hidden, for: .windowToolbar)
        }
    }

    /// A workroom's terminal, with its setup log (if any) docked underneath.
    @ViewBuilder
    private func workroomDetail(_ workroom: Workroom) -> some View {
        VStack(spacing: 0) {
            WorkroomTerminalsView(workroom: workroom, sessions: store.terminals)

            if let log = store.logs[workroom.id] {
                Divider()
                ScriptLogPanel(session: log) { store.logs[workroom.id] = nil }
            }
        }
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
}

/// The header + scrolling body of a setup log. Shared between the full-pane create
/// view and the resizable under-terminal panel.
struct ScriptLogContent: View {
    @ObservedObject var session: ScriptLogSession
    var onClose: () -> Void

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
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) }
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
            .fill(Color.secondary.opacity(0.0001)) // invisible but hit-testable
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
