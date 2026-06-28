import AppKit
import SwiftUI

/// Maps whole-file highlight spans onto a file's lines, producing one coloured `AttributedString`
/// per line (0-based, line order). Pure (no I/O, no parse) — the byte↔line arithmetic mirrors
/// `DiffHighlightMapper`, but without a diff: every line is the theme foreground with captured spans
/// recoloured. Used by the read-only `PlainFileViewer`; unit-tested without a parser or UI.
enum FileHighlightMapper {
  /// Build one `AttributedString` per file line from `spans` over the whole-file `content`.
  /// Uncaptured text uses the theme foreground; captured spans use the syntax colour. A trailing
  /// newline does not add a phantom empty final line. Returns `[]` for empty content.
  static func attributedLines(content: String, spans: [HighlightSpan], tokens: ThemeTokens)
    -> [AttributedString]
  {
    let bytes = Array(content.utf8)
    guard !bytes.isEmpty else { return [] }

    // Line byte ranges. `lineEnd` excludes the trailing `\n` (a `\r` before it stays in the line).
    var lineStart: [Int] = [0]
    var lineEnd: [Int] = []
    for (i, b) in bytes.enumerated() where b == 0x0A {
      lineEnd.append(i)
      lineStart.append(i + 1)
    }
    lineEnd.append(bytes.count)
    // Content ending in `\n` yields a trailing empty line range — drop it so we don't render a blank
    // final row (the line count then matches what an editor shows).
    let lineCount =
      (lineStart.count > 1 && lineStart[lineStart.count - 1] == bytes.count)
      ? lineStart.count - 1 : lineStart.count

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

    // Bucket spans per line, splitting a multiline span (block comment, multiline string) across the
    // lines it covers. Input spans are ascending + non-overlapping, so each bucket stays ascending.
    var buckets: [[HighlightSpan]] = Array(repeating: [], count: lineCount)
    for span in spans {
      let lo = span.byteRange.lowerBound
      let hi = min(span.byteRange.upperBound, bytes.count)
      guard lo < hi else { continue }
      let first = lineIndex(forByte: lo)
      let last = lineIndex(forByte: hi - 1)
      guard first < lineCount else { continue }
      for l in first...min(last, lineCount - 1) {
        let s = max(lo, lineStart[l])
        let e = min(hi, lineEnd[l])
        if s < e { buckets[l].append(HighlightSpan(byteRange: s..<e, capture: span.capture)) }
      }
    }

    let defaultColor = Color(nsColor: tokens.nsFg)
    var result: [AttributedString] = []
    result.reserveCapacity(lineCount)

    for idx in 0..<lineCount {
      var attr = AttributedString()
      var cursor = lineStart[idx]

      func emit(_ range: Range<Int>, _ color: Color) {
        guard range.lowerBound < range.upperBound else { return }
        var run = AttributedString(String(decoding: bytes[range], as: UTF8.self))
        run.foregroundColor = color
        attr.append(run)
      }

      for span in buckets[idx] {
        if span.byteRange.lowerBound > cursor {
          emit(cursor..<span.byteRange.lowerBound, defaultColor)
        }
        let color = tokens.syntaxColor(forCapture: span.capture) ?? defaultColor
        emit(max(span.byteRange.lowerBound, cursor)..<span.byteRange.upperBound, color)
        cursor = max(cursor, span.byteRange.upperBound)
      }
      if cursor < lineEnd[idx] { emit(cursor..<lineEnd[idx], defaultColor) }
      result.append(attr)
    }
    return result
  }

  /// Build a single themed `NSAttributedString` for the whole file — the text the `NSTextView`-backed
  /// `CodeTextView` renders (SwiftUI `Text` can't select across lines). Every character starts in the
  /// theme foreground + `font`; captured spans are recoloured. `spans == []` yields a plain (but still
  /// monospaced + themed) string. Spans are UTF-8 byte ranges (tree-sitter), converted to the
  /// `NSAttributedString`'s UTF-16 ranges via one forward walk (spans are ascending + non-overlapping,
  /// so the cursor only moves forward).
  static func nsAttributedString(
    content: String, spans: [HighlightSpan], tokens: ThemeTokens, font: NSFont
  ) -> NSAttributedString {
    let result = NSMutableAttributedString(string: content)
    let full = NSRange(location: 0, length: result.length)
    result.addAttribute(.font, value: font, range: full)
    result.addAttribute(.foregroundColor, value: tokens.nsFg, range: full)
    guard !spans.isEmpty else { return result }

    let byteCount = content.utf8.count
    var index = content.startIndex
    var byte = 0
    for span in spans {
      let lo = span.byteRange.lowerBound
      let hi = min(span.byteRange.upperBound, byteCount)
      guard lo < hi, lo >= byte else { continue }
      while byte < lo, index < content.endIndex {
        byte += content[index].utf8.count
        index = content.index(after: index)
      }
      let start = index
      while byte < hi, index < content.endIndex {
        byte += content[index].utf8.count
        index = content.index(after: index)
      }
      guard start < index else { continue }
      let color = tokens.syntaxColor(forCapture: span.capture).map { NSColor($0) } ?? tokens.nsFg
      result.addAttribute(
        .foregroundColor, value: color, range: NSRange(start..<index, in: content))
    }
    return result
  }
}
