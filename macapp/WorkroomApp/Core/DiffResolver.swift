import Foundation

/// The outcome of a `DiffResolver.resolve` call.
enum DiffResult: Equatable, Sendable {
  /// A parseable text diff.
  case diff(UnifiedDiff)
  /// The VCS reported binary content; there are no textual hunks to render.
  case binary
  /// No differences (the file is clean / unchanged for this source).
  case empty
  /// The command failed or timed out. The associated value is a short human-readable message
  /// (the first non-empty stderr line, or a generic fallback).
  case failed(String)
}

/// Resolves the diff for a single `DiffDescriptor` by shelling to `git` or `jj`. Pure — all VCS
/// specifics are in `command(for:dir:)` (unit-tested without spawning). `resolve(_:in:)` calls
/// the runner, interprets the result, and parses the unified diff.
struct DiffResolver: Sendable {
  let runner: StatusCommandRunning
  var timeout: TimeInterval

  init(runner: StatusCommandRunning = StatusCommandRunner(), timeout: TimeInterval = 5) {
    self.runner = runner
    self.timeout = timeout
  }

  /// Fetch and parse the diff for `descriptor`, running the VCS command in `dir` (the workroom
  /// directory, an absolute path). Returns a `DiffResult` that the diff viewer renders directly.
  func resolve(_ descriptor: DiffDescriptor, in dir: String) async -> DiffResult {
    let (exe, args) = Self.command(for: descriptor, dir: dir)
    let r = await runner.run(exe, args, in: dir, timeout: timeout)

    // The --no-index (untracked) case: git exits 1 when files differ — that's success.
    let isUntrackedGit =
      descriptor.source == .gitWorktree && descriptor.change == .untracked
    let success: Bool
    if r.timedOut {
      return .failed("Timed out")
    } else if isUntrackedGit {
      success = r.exitCode == 0 || r.exitCode == 1
    } else {
      success = r.ok
    }

    guard success else {
      let msg =
        r.stderr.split(whereSeparator: \.isNewline).map(String.init)
        .first(where: { !$0.isEmpty }) ?? "Diff unavailable"
      return .failed(msg)
    }

    if UnifiedDiff.isBinary(r.stdout) { return .binary }
    if r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
    return .diff(UnifiedDiff.parse(r.stdout))
  }

  /// Pure command builder — the executable and arguments for the given descriptor.
  ///
  /// `dir` is needed only for the `gitWorktree` + `untracked` case, where git's `--no-index`
  /// requires absolute paths. All git invocations prepend `WorkroomStatusResolver.gitHardening`
  /// to neutralise `core.fsmonitor` and related config (security-critical; must not drift).
  static func command(for descriptor: DiffDescriptor, dir: String) -> (exe: String, args: [String])
  {
    let path = descriptor.path
    let hardening = WorkroomStatusResolver.gitHardening
    let gitBase =
      hardening + [
        "-c", "core.quotePath=false",
        "diff", "--no-ext-diff", "--no-textconv", "--no-color",
      ]

    switch descriptor.source {
    case .jjWorkingCopy:
      return ("jj", ["diff", "--git", "-r", "@", "--color", "never", "--", path])

    case .jjParent:
      return (
        "jj",
        ["diff", "--git", "-r", "@-", "--ignore-working-copy", "--color", "never", "--", path]
      )

    case .gitWorktree:
      switch descriptor.change {
      case .untracked:
        // --no-index compares two arbitrary paths; /dev/null stands in for "no old file".
        let absPath = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: dir))
          .standardizedFileURL.path
        return (
          "git",
          hardening + [
            "-c", "core.quotePath=false", "diff", "--no-ext-diff",
            "--no-textconv", "--no-color", "--no-index", "--", "/dev/null", absPath,
          ]
        )

      case .renamed:
        return ("git", gitBase + ["-M", "HEAD", "--", path])

      default:
        return ("git", gitBase + ["HEAD", "--", path])
      }
    }
  }
}

// MARK: - New-file content (for syntax highlighting)

extension DiffResolver {
  /// The **new-side** file content for syntax highlighting, or `nil` ⇒ the caller renders the diff
  /// plain. Folded into `DiffResolver` (one hardened command-runner surface) rather than a second
  /// VCS-fetch service.
  ///
  /// - For working-copy sources (`gitWorktree`, `jjWorkingCopy`) the new side *is* the working file
  ///   on disk → a guarded disk read (the working copy is `@`, so we never shell out and never
  ///   contend on the jj working-copy lock).
  /// - For the jj **parent** (`@-`) the new side is the parent commit's version (not on disk) →
  ///   `jj file show -r @- --ignore-working-copy` (never `-r @`).
  ///
  /// Only additions + context are highlighted from this content; deletions render plain, so a
  /// deleted file (no new side) correctly yields `nil`.
  func fileContent(for descriptor: DiffDescriptor, in dir: String) async -> String? {
    switch descriptor.source {
    case .gitWorktree, .jjWorkingCopy:
      return Self.readWorkingFile(path: descriptor.path, in: dir)
    case .jjParent:
      let (exe, args) = Self.parentShowCommand(path: descriptor.path)
      let r = await runner.run(exe, args, in: dir, timeout: timeout)
      guard r.ok, !r.stdout.isEmpty else { return nil }
      // The runner caps stdout (4MB). If the file is at/over our parse cap, don't highlight
      // (truncated content would mis-map byte offsets) — render plain.
      guard r.stdout.utf8.count <= SyntaxLanguage.byteCap else { return nil }
      return r.stdout
    }
  }

  /// The jj command for the parent commit's version of a file. Pure (unit-tested): MUST target
  /// `@-` with `--ignore-working-copy` and MUST NOT pass `-r @` (which would take the working-copy
  /// lock the status sweep contends on).
  static func parentShowCommand(path: String) -> (exe: String, args: [String]) {
    ("jj", ["file", "show", "-r", "@-", "--ignore-working-copy", "--", path])
  }

  /// Read a working-copy file for highlighting, guarded against the traps a syntax parse would
  /// otherwise hit (a symlink whose *target text* git diffs, a path escaping the workroom, an
  /// over-cap file). Returns `nil` (⇒ render plain) on any guard failure or non-UTF-8 content.
  static func readWorkingFile(path: String, in dir: String) -> String? {
    let root = URL(fileURLWithPath: dir, isDirectory: true)
    let target = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL

    // Canonical-path containment: resolve symlinks on BOTH sides (consistently — so /tmp→/private
    // doesn't trip a legit file) and require the real target to live under the real workroom. This
    // catches an intermediate symlinked directory that would otherwise escape via a string prefix.
    let realRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
    let realTarget = target.resolvingSymlinksInPath().standardizedFileURL.path
    guard realTarget == realRoot || realTarget.hasPrefix(realRoot + "/") else { return nil }

    // lstat the leaf (don't follow symlinks): a symlink's diff is its *target path text*, not file
    // content, so parsing it as source would be wrong → render plain. Require a regular file.
    guard
      let values = try? target.resourceValues(forKeys: [
        .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
      ]),
      values.isSymbolicLink != true,
      values.isRegularFile == true,
      let size = values.fileSize, size <= SyntaxLanguage.byteCap
    else { return nil }

    return try? String(contentsOf: target, encoding: .utf8)
  }
}
