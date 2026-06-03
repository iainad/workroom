import SwiftUI

/// The detail pane's terminals for one workroom: a horizontal tab strip below the title
/// bar plus the active terminal. Observes `TerminalSessions` so adding, closing, and
/// switching tabs all update live.
struct WorkroomTerminalsView: View {
    let workroom: Workroom
    @ObservedObject var sessions: TerminalSessions
    @State private var hoveredTab: TerminalTab.ID?
    @State private var addHovering = false

    var body: some View {
        let tabs = sessions.tabs(for: workroom)
        let active = sessions.activeTab(for: workroom)
        VStack(spacing: 0) {
            tabBar(tabs, activeID: active?.id)
            Divider()
            if let active {
                TerminalContainerView(terminal: active.view)
                    .id(active.id) // re-mount when the active tab changes
                    .padding(8)
            } else {
                Color.clear
            }
        }
        // Create the first terminal once the pane appears (and for each new workroom).
        .task(id: workroom.id) { sessions.ensureTab(for: workroom) }
    }

    private func tabBar(_ tabs: [TerminalTab], activeID: TerminalTab.ID?) -> some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        tabChip(tab, isActive: tab.id == activeID, canClose: tabs.count > 1)
                    }
                }
                .padding(.horizontal, 8)
            }
            Button {
                sessions.addTab(for: workroom)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(addHovering ? 0.1 : 0))
                    )
            }
            .buttonStyle(.plain)
            .onHover { addHovering = $0 }
            .padding(.horizontal, 8)
            .help("New terminal")
        }
        .padding(.vertical, 4)
    }

    private func tabChip(_ tab: TerminalTab, isActive: Bool, canClose: Bool) -> some View {
        let showClose = canClose && hoveredTab == tab.id
        return Text(tab.title)
            .font(.callout)
            .lineLimit(1)
            // On hover, fade the title's right edge so the close button — overlaid on top of
            // the text and taking no layout space — reads cleanly. Off-hover there's no fade
            // and no reserved space, so the tab is sized to just its text.
            .mask(
                HStack(spacing: 0) {
                    Rectangle()
                    // Fade the title out, then a fully-clear zone the close button sits in
                    // so there's breathing room around it.
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: showClose ? .clear : .black, location: 0.45),
                            .init(color: showClose ? .clear : .black, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 46)
                }
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(alignment: .trailing) {
                TabCloseButton {
                    sessions.closeTab(tab.id, for: workroom)
                }
                .help("Close \(tab.title)")
                .opacity(showClose ? 1 : 0)
                .allowsHitTesting(showClose)
                .padding(.trailing, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(isActive ? 0.1 : (hoveredTab == tab.id ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hoveredTab = tab.id } else if hoveredTab == tab.id { hoveredTab = nil }
            }
            .onTapGesture { sessions.select(tab.id, for: workroom) }
            .animation(.easeInOut(duration: 0.12), value: showClose)
    }
}

/// A tab's close button, overlaid on the title's right edge. Its own hover paints a subtle
/// background behind the ✕. (Show/hide is handled by the caller's overlay.)
private struct TabCloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(hovering ? 0.15 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
