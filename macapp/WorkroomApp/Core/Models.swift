import Foundation

// Mirrors the `workroom --json` public API (schema_version 1). Decoders are lenient:
// unknown fields are ignored so a newer bundled/standalone CLI won't break the app.

struct Warning: Codable, Hashable {
  let kind: String
  let message: String
  let path: String?
  let vcs: String?
}

struct Workroom: Codable, Identifiable, Hashable {
  let name: String
  let path: String
  let vcsName: String
  let warnings: [Warning]

  var id: String { name }
  var hasBlockingWarning: Bool { warnings.contains { $0.kind == "DirectoryMissing" } }

  enum CodingKeys: String, CodingKey {
    case name, path, warnings
    case vcsName = "vcs_name"
  }
}

struct Project: Codable, Identifiable, Hashable {
  let path: String
  let vcs: String
  let workrooms: [Workroom]

  var id: String { path }
  var displayName: String { (path as NSString).lastPathComponent }
}

// MARK: - Project root (sidebar root row)
//
// The root is the project directory itself — always selectable, always the first child in
// the sidebar, never deletable. Its branch/bookmark label is a GUI-only concern (the
// `workroom` CLI never shows it), so it is resolved app-side by BranchResolver, NOT carried
// in the `list --json` contract.

/// What kind of reference the working copy is on. Drives the root row's label treatment
/// (see RootPresentation). `ref_kind`-style, self-describing — the renderer needs no
/// `project.vcs` cross-reference.
enum RefKind: Hashable {
  case branch  // git: on a branch · jj: bookmark(s) on @
  case ancestor  // jj: no bookmark on @ — showing the nearest ancestor bookmark (the jj norm)
  case detached  // git: detached HEAD — showing a short SHA
  case none  // no branch/bookmark resolvable, or not yet resolved
}

/// A project root's resolved label. `branch` is normalized to nil (never "") so an empty
/// result is unambiguously `.none`.
struct RootRef: Hashable {
  let branch: String?
  let kind: RefKind

  static let unresolved = RootRef(branch: nil, kind: .none)
}

/// A place a terminal can be opened: a workroom or a project root. The id is
/// project-scoped, so same-named workrooms in different projects (and roots) never share a
/// terminal or setup log.
struct TerminalTarget: Identifiable, Hashable {
  let id: String
  let title: String
  let path: String
  let isMissing: Bool

  // The id format lives ONLY here (and in the two builders below). Anything that needs a
  // target id — terminal/log keying, reaping — goes through these, so the project-scoping
  // that fixes the same-name collision can't drift.
  static func workroomID(project: String, name: String) -> String { "wr|\(project)|\(name)" }
  static func rootID(project: String) -> String { "root|\(project)" }
}

extension Workroom {
  /// The terminal target for this workroom within `projectPath`.
  func target(inProject projectPath: String) -> TerminalTarget {
    TerminalTarget(
      id: TerminalTarget.workroomID(project: projectPath, name: name),
      title: name, path: path, isMissing: hasBlockingWarning)
  }
}

extension Project {
  /// The always-present project-root target. The project directory can disappear like a
  /// workroom directory, so `isMissing` is checked against the filesystem.
  var rootTarget: TerminalTarget {
    TerminalTarget(
      id: TerminalTarget.rootID(project: path), title: displayName, path: path,
      isMissing: !FileManager.default.fileExists(atPath: path))
  }
}

/// Pure mapping from a resolved `RootRef` to the root row's visual treatment. Extracted
/// from the view so it is unit-testable. `dim` means "unusual" (detached / no branch); the
/// jj-common `ancestor` state reads healthy (full strength + an `ahead` marker).
enum RootPresentation {
  struct Style: Equatable {
    let label: String
    let tooltip: String
    let accessibility: String
    let ahead: Bool  // trailing "↑" marker (jj ancestor)
    let dim: Bool  // de-emphasize (detached / none)
  }

  static func make(_ ref: RootRef) -> Style {
    switch ref.kind {
    case .branch:
      let name = normalized(ref.branch) ?? "root"
      return Style(
        label: name, tooltip: "Project root · on \(name)",
        accessibility: "Project root, on \(name)", ahead: false, dim: false)
    case .ancestor:
      let name = normalized(ref.branch) ?? "root"
      return Style(
        label: name, tooltip: "Project root · ahead of \(name)",
        accessibility: "Project root, ahead of \(name)", ahead: true, dim: false)
    case .detached:
      let name = normalized(ref.branch) ?? "detached"
      return Style(
        label: name, tooltip: "Project root · detached HEAD",
        accessibility: "Project root, detached at \(name)", ahead: false, dim: true)
    case .none:
      return Style(
        label: "root", tooltip: "Project root",
        accessibility: "Project root", ahead: false, dim: true)
    }
  }

  /// Treats "" / whitespace like nil (the Go side may emit "" rather than null).
  private static func normalized(_ s: String?) -> String? {
    guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return s
  }
}

// MARK: - Envelopes

/// Common envelope header present on every response; used to detect error responses
/// before decoding a command-specific payload.
struct Envelope: Codable {
  let ok: Bool
  let schemaVersion: Int?
  let error: CLIErrorBody?

  enum CodingKeys: String, CodingKey {
    case ok, error
    case schemaVersion = "schema_version"
  }
}

struct CLIErrorBody: Codable {
  let kind: String
  let message: String
}

struct ListResponse: Codable {
  let projects: [Project]
  let workroomsDir: String?
  let configPath: String?

  enum CodingKeys: String, CodingKey {
    case projects
    case workroomsDir = "workrooms_dir"
    case configPath = "config_path"
  }
}

struct CreateResponse: Codable {
  let name: String
  let path: String
  let vcs: String
  let project: String
}

/// `delete-project --from-disk` success payload. The CLI runs teardowns + drops the project
/// from config, then returns the directories (project root first, then workrooms) for the app
/// to move to the Bin — the CLI never deletes them itself (issue #108).
struct DeleteProjectResponse: Codable {
  let trashPaths: [String]?

  enum CodingKeys: String, CodingKey {
    case trashPaths = "trash_paths"
  }
}

/// A streamed event from the CLI's stderr in --json mode (one NDJSON object per line)
/// while the result envelope stays on stdout. `type` discriminates:
///  - "log": a line of setup/teardown output (`text`, `phase`).
///  - "created": the new workroom exists (`name`, `path`) but setup is still running;
///    `setup` reports whether a setup script will run, so the GUI can block on its log.
struct StreamEvent: Decodable {
  let type: String
  let phase: String?
  let text: String?
  let name: String?
  let path: String?
  let setup: Bool?
}
