import Foundation

/// A parsed unified / `--git` diff, broken into hunks. Used by the in-app diff viewer (issue #66)
/// to render old/new side-by-side or inline, with syntax highlighting applied per line.
struct UnifiedDiff: Equatable, Sendable {
  var hunks: [Hunk]
  /// `true` when the line cap was hit and the remainder of the diff was dropped.
  var truncated: Bool
  /// The old path from a `rename from <path>` header, when present; otherwise `nil`.
  var renamedFrom: String?

  struct Hunk: Equatable, Sendable {
    /// Verbatim `@@ -a,b +c,d @@ optional section heading` line.
    var header: String
    var lines: [Line]
  }

  struct Line: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
      case context
      case addition
      case deletion
    }

    var kind: Kind
    /// Content without the leading `+`/`-`/` ` marker; no trailing newline.
    var text: String
    /// 1-based old-file line number; `nil` for additions.
    var oldLine: Int?
    /// 1-based new-file line number; `nil` for deletions.
    var newLine: Int?
  }

  /// Parse unified / `--git` diff text into hunks.
  ///
  /// Skips file headers (`diff --git`, `index`, mode lines, `---`/`+++`), captures `rename from`.
  /// Tracks old/new line numbers from each `@@` header. Stops adding lines once `lineCap` total diff
  /// lines are reached and sets `truncated = true` (the current structure is finished cleanly). A
  /// `\ No newline at end of file` marker is dropped (not a content line). Multi-file diffs have all
  /// their hunks flattened into one list in document order.
  static func parse(_ raw: String, lineCap: Int = 2000) -> UnifiedDiff {
    guard !raw.isEmpty else { return UnifiedDiff(hunks: [], truncated: false, renamedFrom: nil) }

    var hunks: [Hunk] = []
    var renamedFrom: String?
    var truncated = false
    var totalLines = 0

    // Current hunk state
    var currentHeader: String?
    var currentLines: [Line] = []
    var oldLineNo: Int = 1
    var newLineNo: Int = 1

    func flushHunk() {
      guard let header = currentHeader else { return }
      hunks.append(Hunk(header: header, lines: currentLines))
      currentHeader = nil
      currentLines = []
    }

    // Regex for @@ -oldStart[,oldCount] +newStart[,newCount] @@ [heading]
    let hhPattern = try? NSRegularExpression(
      pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)"#)

    for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)

      // File-level headers — flush the previous hunk and skip
      if line.hasPrefix("diff --git ") || line.hasPrefix("index ")
        || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
        || line.hasPrefix("old mode") || line.hasPrefix("new mode")
        || line.hasPrefix("similarity index") || line.hasPrefix("dissimilarity index")
        || line.hasPrefix("copy from ") || line.hasPrefix("copy to ")
        || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
      {
        flushHunk()
        continue
      }

      if line.hasPrefix("rename from ") {
        flushHunk()
        renamedFrom = String(line.dropFirst("rename from ".count))
        continue
      }

      if line.hasPrefix("rename to ") {
        flushHunk()
        continue
      }

      // `\ No newline at end of file` — drop
      if line.hasPrefix("\\ ") {
        continue
      }

      // Hunk header
      if line.hasPrefix("@@") {
        flushHunk()
        if let m = hhPattern?.firstMatch(
          in: line, range: NSRange(line.startIndex..., in: line))
        {
          func capture(_ idx: Int) -> String {
            let r = m.range(at: idx)
            guard r.location != NSNotFound, let range = Range(r, in: line) else { return "" }
            return String(line[range])
          }
          oldLineNo = Int(capture(1)) ?? 1
          newLineNo = Int(capture(2)) ?? 1
        } else {
          oldLineNo = 1
          newLineNo = 1
        }
        currentHeader = line
        currentLines = []
        continue
      }

      // Hunk content — only process when we're inside a hunk
      guard currentHeader != nil else { continue }

      if truncated { continue }

      let firstChar = line.first
      switch firstChar {
      case " ":
        let text = String(line.dropFirst())
        currentLines.append(
          Line(kind: .context, text: text, oldLine: oldLineNo, newLine: newLineNo))
        oldLineNo += 1
        newLineNo += 1
        totalLines += 1
      case "+":
        let text = String(line.dropFirst())
        currentLines.append(Line(kind: .addition, text: text, oldLine: nil, newLine: newLineNo))
        newLineNo += 1
        totalLines += 1
      case "-":
        let text = String(line.dropFirst())
        currentLines.append(Line(kind: .deletion, text: text, oldLine: oldLineNo, newLine: nil))
        oldLineNo += 1
        totalLines += 1
      default:
        // Unrecognised line inside a hunk — treat as context to stay robust
        currentLines.append(
          Line(kind: .context, text: line, oldLine: oldLineNo, newLine: newLineNo))
        oldLineNo += 1
        newLineNo += 1
        totalLines += 1
      }

      if totalLines >= lineCap {
        truncated = true
      }
    }

    flushHunk()

    return UnifiedDiff(hunks: hunks, truncated: truncated, renamedFrom: renamedFrom)
  }

  /// `true` when the diff output is the binary sentinel — either the one-line
  /// `Binary files a/x and b/x differ` message, or a `GIT binary patch` block. When `true`
  /// there are no textual hunks to render.
  static func isBinary(_ raw: String) -> Bool {
    for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if line.hasPrefix("Binary files") && line.hasSuffix("differ") { return true }
      if line.hasPrefix("GIT binary patch") { return true }
    }
    return false
  }
}
