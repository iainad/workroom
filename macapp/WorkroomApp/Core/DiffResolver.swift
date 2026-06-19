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
