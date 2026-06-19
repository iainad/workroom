import SwiftUI

/// Pure presentation rules for `DeleteProjectSheet`, extracted so the disable-until-match,
/// Delete-button label, and escalating footer logic are unit-testable without rendering SwiftUI.
enum DeleteProjectSheetModel {
  /// Delete is enabled only on an exact (case-sensitive) match of the project's display name.
  static func nameMatches(typed: String, displayName: String) -> Bool {
    typed == displayName
  }

  static func deleteLabel(workroomCount: Int, cascade: Bool) -> String {
    let plural = workroomCount == 1 ? "" : "s"
    return cascade
      ? "Delete Project & \(workroomCount) Workroom\(plural)" : "Delete Project"
  }

  /// Reflects the toggle: config-only keeps everything on disk; cascade warns about the dirs.
  /// Branches are kept in both cases.
  static func effectFooter(workroomCount: Int, cascade: Bool) -> String {
    if workroomCount > 0 && cascade {
      return
        "⚠️ Permanently deletes \(workroomCount) worktree "
        + "director\(workroomCount == 1 ? "y" : "ies") and their files on disk. Branches are kept."
    }
    return
      "Removes the project from Workroom only. Worktrees, branches, and files on disk are kept."
  }
}

/// Type-to-confirm sheet for deleting a project (issue #61). Opened from the project row's
/// context menu. The full path is always shown (same-named projects in different parents must
/// be distinguishable), and Delete stays disabled until the typed name matches exactly.
///
/// When the project still has workrooms, a default-OFF toggle offers to cascade the delete to
/// them (their worktree directories + files on disk). The footer + Delete-button label escalate
/// to make the destructive option unmistakable. Branches/bookmarks are NEVER deleted in either
/// mode — the cascade reuses the per-workroom teardown, which leaves refs intact.
///
/// `onDelete(Bool)` passes the cascade toggle state; the parent owns clearing the pending state.
struct DeleteProjectSheet: View {
  let project: Project
  let onDelete: (_ withWorkrooms: Bool) -> Void
  let onCancel: () -> Void

  @State private var typedName = ""
  @State private var alsoDeleteWorkrooms = false
  @FocusState private var nameFieldFocused: Bool

  private var hasWorkrooms: Bool { !project.workrooms.isEmpty }
  private var count: Int { project.workrooms.count }
  private var plural: String { count == 1 ? "" : "s" }
  private var nameMatches: Bool {
    DeleteProjectSheetModel.nameMatches(typed: typedName, displayName: project.displayName)
  }
  private var deleteLabel: String {
    DeleteProjectSheetModel.deleteLabel(workroomCount: count, cascade: alsoDeleteWorkrooms)
  }
  private var effectFooter: String {
    DeleteProjectSheetModel.effectFooter(workroomCount: count, cascade: alsoDeleteWorkrooms)
  }

  var body: some View {
    // Everything is left-aligned for one consistent edge; only the action buttons keep the
    // platform-standard trailing placement. A plain (non-Form) layout is used deliberately —
    // the grouped Form right-aligned the field's value, which broke that alignment.
    VStack(alignment: .leading, spacing: 16) {
      // Title + full path, led by a prominent warning glyph.
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 30))
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text("Delete project “\(project.displayName)”?")
            .font(.headline)
          Text(project.path)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(project.path)
        }
      }

      if hasWorkrooms {
        VStack(alignment: .leading, spacing: 8) {
          Text("This project has \(count) workroom\(plural)")
            .font(.subheadline.weight(.semibold))
          ScrollView {
            VStack(alignment: .leading, spacing: 4) {
              ForEach(project.workrooms) { workroom in
                Label(workroom.name, systemImage: "folder")
                  .font(.callout)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 120)
          Toggle(isOn: $alsoDeleteWorkrooms) {
            Text("Also delete \(count) workroom\(plural)")
          }
          .accessibilityIdentifier("deleteProject.cascadeToggle")
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Type the project name to confirm")
          .font(.subheadline.weight(.semibold))
        TextField("Project name", text: $typedName, prompt: Text(project.displayName))
          .textFieldStyle(.roundedBorder)
          .labelsHidden()
          .focused($nameFieldFocused)
          .lineLimit(1)
          .onSubmit { if nameMatches { onDelete(alsoDeleteWorkrooms) } }
          .accessibilityIdentifier("deleteProject.confirmField")
        Text(effectFooter)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()
      HStack {
        Spacer()
        Button("Cancel") { onCancel() }
          .keyboardShortcut(.cancelAction)
        Button(deleteLabel) { onDelete(alsoDeleteWorkrooms) }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .tint(.red)
          .disabled(!nameMatches)
          .accessibilityIdentifier("deleteProject.confirmButton")
      }
    }
    .padding(20)
    .frame(width: 460)
    .onAppear { nameFieldFocused = true }
  }
}
