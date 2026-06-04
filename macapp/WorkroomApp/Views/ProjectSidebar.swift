import SwiftUI
import UniformTypeIdentifiers

/// The sidebar: a collapsible tree with projects at the root and their workrooms nested
/// one level below. Selecting a workroom opens its terminal in the detail pane; selecting
/// a project makes it the target for "New Workroom". Projects expand/collapse via the
/// leading chevron.
struct ProjectSidebar: View {
  @EnvironmentObject var store: AppStore
  @State private var showImporter = false
  /// Project paths the user has collapsed. Absence means expanded (the default).
  @State private var collapsed: Set<String> = []
  @State private var hovered: SidebarID?
  @State private var themeHovering = false
  @AppStorage(ThemePreference.storageKey) private var theme: ThemePreference = .system

  /// Width of the leading icon gutter shared by every child row, so the root's house icon
  /// and the (icon-less) workroom labels line up in one column.
  private let gutterWidth: CGFloat = 18
  /// Leading inset for child rows (root + workrooms) so they nest under the project. Shared
  /// by both rows — they MUST match for the label column to align.
  private let childLeading: CGFloat = 10

  /// Both the root and the workrooms are selectable targets (clicking a *project* toggles
  /// its expansion instead). The List selection is the store's selected target id; setting
  /// it also follows the New-Workroom context project.
  private var selection: Binding<SidebarID?> {
    Binding(
      get: { store.selectedTargetID },
      set: { newValue in
        store.selectedTargetID = newValue
        switch newValue {
        case .root(let path), .workroom(let path, _):
          store.selectedProjectID = path
        default:
          break
        }
      }
    )
  }

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
        tree
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
    .confirmationDialog(
      store.pendingDeletion.map { "Delete '\($0.workroom.name)'?" } ?? "Delete workroom?",
      isPresented: Binding(
        get: { store.pendingDeletion != nil }, set: { if !$0 { store.pendingDeletion = nil } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        if let target = store.pendingDeletion {
          store.deleteWorkroom(target.workroom, in: target.project)
        }
        store.pendingDeletion = nil
      }
      Button("Cancel", role: .cancel) { store.pendingDeletion = nil }
    } message: {
      Text(
        "This removes the workroom's directory and runs its teardown script. For Git, the branch is left in place."
      )
    }
  }

  /// Flat list of tagged rows (project, then its workrooms when expanded) — the
  /// hierarchy is conveyed by the chevron and the workroom indent. A flat structure
  /// keeps List selection and keyboard navigation simple across both levels.
  private var tree: some View {
    List(selection: selection) {
      ForEach(store.projects) { project in
        projectRow(project)
          .listRowBackground(rowHighlight(.project(project.path), selected: false))
        if isExpanded(project.path) {
          // The root is always the first child, before any workrooms.
          let rid = SidebarID.root(project: project.path)
          rootRow(project)
            .tag(rid)
            .listRowBackground(rowHighlight(rid, selected: store.selectedTargetID == rid))
          ForEach(project.workrooms) { workroom in
            let wid = SidebarID.workroom(project: project.path, name: workroom.name)
            workroomRow(workroom, in: project)
              .tag(wid)
              .listRowBackground(rowHighlight(wid, selected: store.selectedTargetID == wid))
          }
        }
      }
    }
  }

  // MARK: Rows

  @ViewBuilder
  private func projectRow(_ project: Project) -> some View {
    let id = SidebarID.project(project.path)
    HStack(spacing: 6) {
      // The whole name/chevron area toggles expansion; clicking anywhere on it
      // (including the trailing empty space) collapses or expands the project.
      Button {
        toggle(project.path)
      } label: {
        HStack(spacing: 6) {
          Text(project.displayName).fontWeight(.medium)
          // Always shown: every project has at least the root as a child.
          Image(systemName: isExpanded(project.path) ? "chevron.down" : "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if store.busyProjects.contains(project.path) {
        ProgressView().controlSize(.small)
      } else {
        CreateRowButton(help: "New workroom in \(project.displayName)") {
          Task { await store.createWorkroom(in: project) }
        }
      }
    }
    .contentShape(Rectangle())
    .onHover { inside in
      if inside { hovered = id } else if hovered == id { hovered = nil }
    }
    .contextMenu {
      Button {
        Task { await store.createWorkroom(in: project) }
      } label: {
        Label("New Workroom", systemImage: "plus")
      }
    }
  }

  /// The always-present project-root row: the first child under each project. A leading
  /// house icon in the shared gutter, then the current branch/bookmark. Selectable (opens
  /// a terminal at the project directory); never deletable.
  @ViewBuilder
  private func rootRow(_ project: Project) -> some View {
    let id = SidebarID.root(project: project.path)
    let target = project.rootTarget
    let style = RootPresentation.make(store.rootRefs[project.id] ?? .unresolved)
    HStack(spacing: 6) {
      Image(systemName: "house")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(width: gutterWidth, alignment: .center)
      Text(style.label)
        .font(.callout)
        .foregroundColor(style.dim ? .secondary : .primary)
        .lineLimit(1)
        .truncationMode(.tail)
      if style.ahead {
        Image(systemName: "arrow.up")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if target.isMissing {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .help("Project folder not found")
      }
    }
    .padding(.leading, childLeading)
    .contentShape(Rectangle())
    .help(style.tooltip)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      target.isMissing ? "\(style.accessibility), folder not found" : style.accessibility
    )
    .onHover { inside in
      if inside { hovered = id } else if hovered == id { hovered = nil }
    }
  }

  @ViewBuilder
  private func workroomRow(_ workroom: Workroom, in project: Project) -> some View {
    let id = SidebarID.workroom(project: project.path, name: workroom.name)
    HStack(spacing: 6) {
      // No icon gutter: the workroom label sits at the root's left (icon) edge, so the
      // root and its workrooms read as siblings rather than nesting workrooms under the
      // root's branch text.
      Text(workroom.name).font(.callout)
      Spacer()
      ForEach(workroom.warnings, id: \.kind) { warning in
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
          .help(warning.message)
      }
      DeleteRowButton(name: workroom.name, visible: hovered == id) {
        store.pendingDeletion = PendingWorkroomDeletion(workroom: workroom, project: project)
      }
    }
    .padding(.leading, childLeading)
    .contentShape(Rectangle())
    .onHover { inside in
      if inside { hovered = id } else if hovered == id { hovered = nil }
    }
    .contextMenu {
      Button(role: .destructive) {
        store.pendingDeletion = PendingWorkroomDeletion(workroom: workroom, project: project)
      } label: {
        Label("Delete \(workroom.name)", systemImage: "trash")
      }
    }
  }

  /// Row highlight drawn at the row-background level so hover and selection share the
  /// same (smaller, inset) geometry. Selected rows get a stronger fill; hovered rows a
  /// subtle one. Drawn ourselves so we control the size rather than the full-row system
  /// selection highlight.
  @ViewBuilder
  private func rowHighlight(_ id: SidebarID, selected: Bool) -> some View {
    let opacity = selected ? 0.13 : (hovered == id ? 0.07 : 0)
    RoundedRectangle(cornerRadius: 6)
      .fill(Color.primary.opacity(opacity))
      .padding(.horizontal, 8)
      .padding(.vertical, 1)
  }

  // MARK: Expansion

  private func isExpanded(_ path: String) -> Bool { !collapsed.contains(path) }

  private func toggle(_ path: String) {
    if collapsed.contains(path) { collapsed.remove(path) } else { collapsed.insert(path) }
  }

  // MARK: Chrome

  /// Bottom-left appearance toggle. One click cycles System → Light → Dark; the icon
  /// and tooltip reflect the active mode.
  private var themeToggle: some View {
    HStack {
      Button {
        theme = theme.next
      } label: {
        Image(systemName: theme.symbol)
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(Color.primary.opacity(themeHovering ? 0.1 : 0))
          )
      }
      .buttonStyle(.plain)
      .onHover { themeHovering = $0 }
      .help("Theme: \(theme.label) — click to switch to \(theme.next.label)")
      .accessibilityLabel("Theme: \(theme.label)")

      Spacer()
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }
}

/// The always-visible "new workroom" button on a project row. Its own hover paints a
/// subtle neutral background to read as an actionable control.
private struct CreateRowButton: View {
  let help: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(hovering ? 0.1 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help(help)
  }
}

/// The trash button revealed when a workroom row is hovered. It is always laid out (so
/// the row's size doesn't change on hover) and only made visible via `visible`. Its own
/// hover paints a soft pastel-red background to flag the destructive action.
private struct DeleteRowButton: View {
  let name: String
  let visible: Bool
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Image(systemName: "trash")
        .font(.system(size: 11))
        .foregroundStyle(hovering ? Color.red : .secondary)
        .padding(4)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.red.opacity(hovering ? 0.18 : 0))
        )
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .help("Delete \(name)")
    .opacity(visible ? 1 : 0)
    .allowsHitTesting(visible)
  }
}
