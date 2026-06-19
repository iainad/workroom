import SwiftUI

/// Maps whole-file highlight spans onto a diff's lines, producing one coloured `AttributedString`
/// per **new-file line number** for the added/context lines. Pure (no I/O, no parse) and the single
/// home of the byte↔offset arithmetic, so the tricky cases (CRLF, retained `\r`, no final newline,
/// multibyte/combining characters) are unit-testable without a parser or a UI.
///
/// Deletions are never highlighted (their new side doesn't exist — they render plain). A line whose
/// diff text no longer matches the file's line is skipped (degrade to plain): this is the
/// changed-since-diff / symlink-target guard — a mid-edit race can't mis-map colours onto the
/// wrong text.
enum DiffHighlightMapper {
  /// Build `newLine → AttributedString` for the highlightable lines of `diff`, from `spans` over the
  /// whole-new-file `content`. Uncaptured text uses the theme foreground; captured spans use the
  /// syntax colour (with the add-background contrast guard for added lines). Empty lines are left
  /// plain. Returns an empty map if there's nothing to colour.
  static func attributedLines(
    diff: UnifiedDiff, content: String, spans: [HighlightSpan], tokens: ThemeTokens,
    additionEmphasis: [Int: Range<Int>] = [:]
  ) -> [Int: AttributedString] {
    let bytes = Array(content.utf8)
    guard !bytes.isEmpty else { return [:] }

    // File line byte ranges. `lineEnd` excludes the trailing `\n` (a `\r` before it stays in the
    // line, so CRLF content matches git's line text). Content ending in `\n` yields a final empty
    // line, which is harmless (no non-empty diff line maps to it).
    var lineStart: [Int] = [0]
    var lineEnd: [Int] = []
    for (i, b) in bytes.enumerated() where b == 0x0A {
      lineEnd.append(i)
      lineStart.append(i + 1)
    }
    lineEnd.append(bytes.count)
    let lineCount = lineStart.count

    // The line index containing byte offset `b` (largest i with lineStart[i] <= b).
    func lineIndex(forByte b: Int) -> Int {
      var lo = 0
      var hi = lineCount - 1
      var ans = 0
      while lo <= hi {
        let mid = (lo + hi) / 2
        if lineStart[mid] <= b {
          ans = mid
          lo = mid + 1
        } else {
          hi = mid - 1
        }
      }
      return ans
    }

    // Bucket spans per line (clamped to the line), splitting multiline spans (block comments,
    // multiline strings) across the lines they cover. Input spans are ascending + non-overlapping,
    // so each bucket stays ascending.
    var buckets: [[HighlightSpan]] = Array(repeating: [], count: lineCount)
    for span in spans {
      let lo = span.byteRange.lowerBound
      let hi = min(span.byteRange.upperBound, bytes.count)
      guard lo < hi else { continue }
      let first = lineIndex(forByte: lo)
      let last = lineIndex(forByte: hi - 1)
      for l in first...last {
        let s = max(lo, lineStart[l])
        let e = min(hi, lineEnd[l])
        if s < e { buckets[l].append(HighlightSpan(byteRange: s..<e, capture: span.capture)) }
      }
    }

    let defaultColor = Color(nsColor: tokens.nsFg)
    var result: [Int: AttributedString] = [:]

    for hunk in diff.hunks {
      for line in hunk.lines {
        guard line.kind != .deletion, !line.text.isEmpty, let newLine = line.newLine else {
          continue
        }
        let idx = newLine - 1
        guard idx >= 0, idx < lineCount else { continue }

        // Changed-since-diff guard: the file's line must still be exactly the diff's line text.
        let fileLineText = String(decoding: bytes[lineStart[idx]..<lineEnd[idx]], as: UTF8.self)
        guard fileLineText == line.text else { continue }

        let onAdded = line.kind == .addition
        var attr = AttributedString()
        var cursor = lineStart[idx]

        // The intra-line change emphasis for this added line, as a file-global byte range.
        let emphasis: Range<Int>? =
          onAdded
          ? additionEmphasis[newLine].map {
            (lineStart[idx] + $0.lowerBound)..<(lineStart[idx] + $0.upperBound)
          }
          : nil

        func emit(_ range: Range<Int>, _ fg: Color, _ bg: Color?) {
          guard range.lowerBound < range.upperBound else { return }
          var run = AttributedString(String(decoding: bytes[range], as: UTF8.self))
          run.foregroundColor = fg
          if let bg { run.backgroundColor = bg }
          attr.append(run)
        }

        // Append a foreground run, splitting it at the emphasis boundaries so the changed bytes get
        // the deeper background tint. Called with ascending ranges, so the sub-runs stay ordered.
        // Each sub-range is bounds-checked *before* constructing it — `a..<b` traps when `a > b`,
        // which happens whenever the run lies entirely before or after the emphasis range.
        func appendRun(_ range: Range<Int>, _ color: Color) {
          let lo = range.lowerBound
          let hi = range.upperBound
          guard lo < hi else { return }
          guard let emphasis else { return emit(lo..<hi, color, nil) }
          let beforeHi = min(hi, emphasis.lowerBound)
          if lo < beforeHi { emit(lo..<beforeHi, color, nil) }
          let inLo = max(lo, emphasis.lowerBound)
          let inHi = min(hi, emphasis.upperBound)
          if inLo < inHi { emit(inLo..<inHi, color, tokens.diffAddEmphasisBg) }
          let afterLo = max(lo, emphasis.upperBound)
          if afterLo < hi { emit(afterLo..<hi, color, nil) }
        }

        for span in buckets[idx] {
          if span.byteRange.lowerBound > cursor {
            appendRun(cursor..<span.byteRange.lowerBound, defaultColor)
          }
          let color =
            tokens.syntaxColor(forCapture: span.capture, onAddedBackground: onAdded) ?? defaultColor
          appendRun(max(span.byteRange.lowerBound, cursor)..<span.byteRange.upperBound, color)
          cursor = max(cursor, span.byteRange.upperBound)
        }
        if cursor < lineEnd[idx] { appendRun(cursor..<lineEnd[idx], defaultColor) }

        result[newLine] = attr
      }
    }
    return result
  }
}
