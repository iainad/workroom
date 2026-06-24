import Foundation

/// Runs a short command in `directory` and returns its trimmed stdout, or nil on error,
/// non-zero exit, or timeout. A seam (mirrors the Go `CommandExecutor`) so `BranchResolver`
/// can be unit-tested without spawning real git/jj.
protocol CommandRunning: Sendable {
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> String?
}

/// Resolves a project root's current branch/bookmark by shelling out to git/jj. Resolution
/// is app-side because the label is a GUI-only concern — the `workroom` CLI never shows it
/// — and because resolving per project (rather than inside `list --json`) keeps the list
/// instant and isolates a slow/wedged repo to its own row. Best-effort: any failure or
/// timeout yields `.none` for that project and never affects others.
struct BranchResolver {
  let runner: CommandRunning
  /// Per-call ceiling so one hung repo abandons only its own label.
  var timeout: TimeInterval

  init(runner: CommandRunning = ProcessCommandRunner(), timeout: TimeInterval = 3) {
    self.runner = runner
    self.timeout = timeout
  }

  func resolve(path: String, vcs: String) async -> RootRef {
    switch vcs {
    case "git": return await resolveGit(path)
    case "jj": return await resolveJJ(path)
    default: return .unresolved
    }
  }

  private func resolveGit(_ dir: String) async -> RootRef {
    // symbolic-ref succeeds whenever HEAD points at a branch — including an *unborn*
    // repo (HEAD → refs/heads/main before the first commit). A detached HEAD fails it.
    if let name = await run(dir, "git", "symbolic-ref", "--quiet", "--short", "HEAD"),
      !name.isEmpty
    {
      return RootRef(branch: name, kind: .branch)
    }
    if let sha = await run(dir, "git", "rev-parse", "--short", "HEAD"), !sha.isEmpty {
      return RootRef(branch: sha, kind: .detached)
    }
    return .unresolved
  }

  private func resolveJJ(_ dir: String) async -> RootRef {
    // `--ignore-working-copy` keeps resolution read-only: jj would otherwise snapshot the working
    // copy (writing under `.jj/`) on every `log`, which both mutates the repo for a mere label read
    // and self-triggers the root-branch filesystem watcher into a refresh loop (see
    // `AppStore.handleRootBranchChange`). The bookmark we want is already recorded, so the snapshot
    // is unnecessary. Mirrors `WorkroomStatusResolver`'s jj reads.
    // Bookmarks pointing exactly at the working copy.
    if let out = await run(
      dir, "jj", "log", "-r", "@", "--ignore-working-copy", "--no-graph", "--color", "never",
      "-T", "bookmarks"),
      let name = Self.firstBookmark(out)
    {
      return RootRef(branch: name, kind: .branch)
    }
    // Otherwise the nearest ancestor bookmark (the jj norm — the working copy is an
    // anonymous change ahead of, say, `master`).
    if let out = await run(
      dir, "jj", "log", "-r", "heads(::@ & bookmarks())", "--ignore-working-copy", "--no-graph",
      "--color", "never", "-T", #"bookmarks ++ "\n""#),
      let name = Self.firstBookmark(out)
    {
      return RootRef(branch: name, kind: .ancestor)
    }
    return .unresolved
  }

  private func run(_ dir: String, _ exe: String, _ args: String...) async -> String? {
    await runner.run(exe, args, in: dir, timeout: timeout)
  }

  /// First bookmark token from jj `bookmarks` template output, with status/sync markers
  /// stripped: jj renders e.g. `main*` / `main??` (conflicted) or `main@origin` (remote).
  /// Multi-line / multi-bookmark output collapses to the first token so the row stays a
  /// single clean label.
  static func firstBookmark(_ output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) {
      for token in line.split(whereSeparator: \.isWhitespace) {
        let cleaned = token.prefix { $0 != "*" && $0 != "?" && $0 != "@" }
        if !cleaned.isEmpty { return String(cleaned) }
      }
    }
    return nil
  }
}

/// Default `CommandRunning`: spawns the command via `/usr/bin/env` (so the augmented PATH
/// finds Homebrew git/jj) with git's prompt/locks disabled, and enforces `timeout` by
/// terminating the process. Output is small (a branch name), so reading to EOF in the
/// termination handler cannot deadlock.
struct ProcessCommandRunner: CommandRunning {
  func run(_ executable: String, _ args: [String], in directory: String, timeout: TimeInterval)
    async -> String?
  {
    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
      let proc = Process()
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      proc.arguments = [executable] + args
      proc.currentDirectoryURL = URL(fileURLWithPath: directory)

      var env = ProcessInfo.processInfo.environment
      env["PATH"] = ShellEnvironment.path()
      env["GIT_OPTIONAL_LOCKS"] = "0"
      env["GIT_TERMINAL_PROMPT"] = "0"
      proc.environment = env

      let outPipe = Pipe()
      proc.standardOutput = outPipe
      proc.standardError = Pipe()  // discard

      let gate = ResumeGate(continuation)

      let timeoutItem = DispatchWorkItem {
        if proc.isRunning { proc.terminate() }
        gate.resume(nil)
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

      proc.terminationHandler = { finished in
        timeoutItem.cancel()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        gate.resume(finished.terminationStatus == 0 ? out : nil)
      }

      do {
        try proc.run()
      } catch {
        timeoutItem.cancel()
        gate.resume(nil)
      }
    }
  }
}

/// Resumes a continuation exactly once across the termination / timeout / launch-failure
/// paths (whichever fires first wins).
private final class ResumeGate: @unchecked Sendable {
  private let lock = NSLock()
  private var done = false
  private let continuation: CheckedContinuation<String?, Never>

  init(_ continuation: CheckedContinuation<String?, Never>) {
    self.continuation = continuation
  }

  func resume(_ value: String?) {
    lock.lock()
    let first = !done
    done = true
    lock.unlock()
    if first { continuation.resume(returning: value) }
  }
}
